module login_server;

import exceptions;
import myth_socket;
import data_store;
import login_connection;
import log;
import host_proxy;
import private_api;
import room_server;
import metaserver_config;

import vibe.vibe;

import std.regex;
import std.string;
import std.algorithm;
import std.random;
import std.uuid;
import std.stdint;
import core.stdc.string; // memcpy
import std.stdio;
import core.memory;
import std.typecons;
import std.array;
import std.datetime.stopwatch : StopWatch, AutoStart;

// Allocate half of the ID space for guests
// Note that Myth inconsistently uses both uint and int for user IDs so we have to
// play it safe and use only positive numbers for IDs.
private immutable first_guest_id = int.max / 2;

// How often we run a cleanup pass
private immutable cleanup_timer_period = 30.seconds;
//private immutable cleanup_timer_period = 5.seconds; // DEBUG/TEST

// How many clients we query for potential removal in each cleanup pass.
// Limit this to avoid processing/bandwidth spikes (mainly in the rooms) on cleanup
private immutable cleanup_max_clients = 200;

// The amount of time a user is given to change rooms before they are considered
// potentially logged off/disconnected and fair game for removal.
private immutable client_disconnected_timeout = 2.seconds;

public alias QueryPlayerInfoReturn QueryPlayerInfo;

/***
* Stores and manages all the state of the server and rooms
*
* NOTE: While we are not currently multithreaded, the presence of blocking functions (mainly HTTP API calls)
* means that the public server interface is re-entrant (by other fibers) and care needs to be taken to avoid
* races and getting into invalid states.
*/
class LoginServer
{
    public this(MetaserverConfig config)
    {
        m_config = config;

        // For stripping Myth "formatting" modifiers ('|b', etc) out of user names
        m_strip_modifiers_regex = regex("\\|[pbilrcsu]", "gi");
        m_next_guest_id = first_guest_id;

        // Set up our data store
        if (m_config.database_connection_string.empty)
        {
            m_data_store = new DataStoreNull();
        }
        else
        {
            m_data_store = new DataStoreMysql(m_config.database_connection_string);
        }

        // Set up the room server directly
        m_room_server = new RoomServer(this, m_config);

        // Start up the HTTP server for status queries
        {
            auto router = new URLRouter;
            router.get("/status.json", &http_status_json);

            auto settings = new HTTPServerSettings;
            settings.port = cast(ushort)m_config.http_server_port;
            settings.errorPageHandler = &http_error_page;
            settings.accessLogFile = m_config.http_server_log_file;

            listenHTTP(settings, router);
        }

        // Set up login listen socket
        listenTCP(cast(ushort)m_config.login_port, &handle_login_connection, "0.0.0.0");

        // Finally, set up some maintainance tasks
        runTask(&cleanup);
    }

    // Launched in a new fiber when a new login connection is made to the server
    private void handle_login_connection(TCPConnection stream)
    {
        auto connection = new LoginConnection(this);
        connection.run(stream);
    }

    // We could cache this but we'd often need to make a copy in the caller to swap endianness anyways.
    private room_info[] get_room_list() const
    {
        return m_room_server.get_room_info().dup;
    }

    public room_info[] get_room_list_for_client(const(Client) client) const
    {
        return specialize_room_list_for_client(client, get_room_list());
    }

    private int generate_unique_guest_id()
    {
        // Find the next number that is currently unused, with wrap-around
        int starting_id = m_next_guest_id;
        while (m_next_guest_id in m_clients)
        {
            if (m_next_guest_id == int.max)
                m_next_guest_id = first_guest_id;
            else
                ++m_next_guest_id;

            // If we got back to the start, blow up
            // This really shouldn't be able to happen in any reasonable way in practice...
            // Implies there are literally billions of guests logged in
            if (m_next_guest_id == starting_id)
                throw new TooManyClientsException();
        }
        return m_next_guest_id++;
    }

    private authentication_token_type generate_unique_authentication_token(int user_id)
    {
        static assert(authentication_token_type.sizeof == 32); // Our breakdown depends on this
        union authentication_token_union
        {
            authentication_token_type token;
            struct {
                ubyte[16] random_uuid;
                ubyte[16] md5_uuid;
            }
        }

        authentication_token_union token;
        token.random_uuid[] = randomUUID().data[];

        ubyte[16] md5_data;
        foreach (ref i; md5_data)
            i = uniform!ubyte();
        memcpy(md5_data.ptr, &user_id, user_id.sizeof);		
        token.md5_uuid[] = md5UUID(md5_data).data[];

        return token.token;
    }

    // Find by user ID
    public Nullable!LoggedInClient find_client(int user_id)
    {
        auto client = user_id in m_clients;
        return client ? Nullable!LoggedInClient(*client) : Nullable!LoggedInClient();
    }

    // Find by auth token
    private Nullable!LoggedInClient find_client(authentication_token_type token)
    {
        foreach (client; m_clients.byValue())
            if (token == client.authentication_token)
                return Nullable!LoggedInClient(client);

        return Nullable!LoggedInClient();
    }

    // Find by auth type/ID

    static public pure nothrow int max_guests()
    {
        return (int.max - first_guest_id + 1);
    }

    private string strip_user_name(string user_name)
    {
        // Sanitize user-name first (remove whitespace and modifiers)
        // NOTE: Strip modifiers *first*, then remove whitespace
        // Avoids "ABC    |p" being unique from "ABC"
        string stripped = std.regex.replace(user_name, m_strip_modifiers_regex, "");
        stripped = strip(stripped);
        
        return stripped;
    }

    // Returns true if the client was kicked from a room
    private bool kick_client_from_rooms(int user_id)
    {
        auto kicked = m_room_server.check_clients_connected([user_id], true);
        if (kicked[0])
            log_message("Login: Kicked client ID %d from room server", user_id);
        return kicked[0];
    }

    // Kick off a check for whether the associated clients have been seen in a room recently.
    // Will update the "last_seen" values for the given clients if so.
    private void update_clients_connected(int[] user_ids)
    {
        if (user_ids.empty) return;

        //log_message("Login: Updating connected status for %s clients...", user_ids.length);

        // TODO: Remove all this now that room servers are no longer separate again
        auto connected = m_room_server.check_clients_connected(user_ids, false);
        foreach (i, user_id; user_ids)
        {
            if (connected[i])
            {
                auto client = find_client(user_id);
                // It's possible that they got kicked out while we were blocking
                if (!client.isNull())
                {
                    //log_message("Login: client ID %d is still connected", client.user_id);
                    client.reset_seen();
                }
            }
        }
    }

    // Update connected status of requested users and - if disconnected - remove them from logged in clients
    // Note that this function may mutate the list of user_ids that is passed in
    // Returns true if ALL clients are disconnected after this function completes
    private bool remove_clients_if_disconnected(int[] user_ids)
    {
        if (user_ids.empty) return true;

        // Ignore any clients who are still within the connected window
        auto user_ids_needing_update = remove!((int user_id) {
            auto client = find_client(user_id);
            return (!client.isNull() && !client.disconnected());
        })(user_ids);
        if (user_ids_needing_update.empty) return false;
            
        // If there are any ambiguous clients, ping the rooms to update the "last seen" values
        update_clients_connected(user_ids_needing_update);

        // And again, ignore any clients who are now within the connected window
        user_ids_needing_update = remove!((int user_id) {
            auto client = find_client(user_id);
            return (!client.isNull() && !client.disconnected());
        })(user_ids_needing_update);
        if (user_ids_needing_update.empty) return false;

        // Now we have to wait some timeout to see if we just happened to catch them between room changes
        // If they do join a room in the interim it will update their "seen" time.
        // NOTE: We technically only have to wait max(remaining disconnect timouts)... meh
        sleep(client_disconnected_timeout); // BLOCKS (obviously)

        // At this point we can safely remove clients that haven't been seen for a while
        // Only return true if we checked on all the users and removed them all
        // NOTE: Probably important that none of this blocks!
        bool removed_all = (user_ids.length == user_ids_needing_update.length);
        foreach (user_id; user_ids_needing_update)
        {
            auto client = find_client(user_id);
            if (client.isNull()) continue;

            if (client.disconnected())
            {
                m_clients.remove(user_id);
                log_message("Login: Removing %s client ID %d (%d clients total)",
                            client.guest ? "guest " : "", client.user_id, m_clients.length);
            }
            else
            {
                removed_all = false;
            }
        }

        return removed_all;
    }

    /***
    * Attempts to add a client to the server.
    * NOTE: These parameters are all "requested" by the user, but the metaserver policy may
    * alter some of them, so be sure to use the ultimate data in the new Client rather than
    * the parameters passed to this function.
    */
    public LoggedInClient add_client(string raw_user_name, string password, string nick_name, string team_name,
                                     rgb_color primary_color, rgb_color secondary_color, byte coat_of_arms_bitmap_index,
                                     short game_version, short build_number, string ip_address,
                                     bool update_player_data)
    {
        log_message("Login: Login attempt for user '%s' from %s...", raw_user_name, ip_address);

        // Empty user names are never allowed. Client shouldn't ever send this, but just in case
        string stripped_user_name = strip_user_name(raw_user_name);        
        if (stripped_user_name.empty)
            throw new BadUserNamePasswordException(raw_user_name);

        if (m_config.nick_name_is_user_name)
            nick_name = raw_user_name; // Allow them to use the version w/ formatting, etc.

        // TODO: Reject empty or otherwise invalid nick names somehow?

        // If guests are enabled, they are done via empty passwords right now
        if (password.empty && !m_config.allow_guests)
        {
            if (build_number >= 428)
                throw new GuestsDisallowedException(raw_user_name);
            else
                throw new BadUserNamePasswordException(raw_user_name);
        }

        UserLoginParams login_params;
        login_params.nick_name = nick_name;
        login_params.team_name = team_name;
        login_params.primary_color = rgb_color_to_int(primary_color);
        login_params.secondary_color = rgb_color_to_int(secondary_color);
        login_params.coat_of_arms_bitmap_index = coat_of_arms_bitmap_index;
        login_params.update_player_data = update_player_data;
        // NOTE: Can block a fiber, and thus this function can be re-entered by another fiber (even for the same user)
        // So be careful about any state that you assume remains consistent across this boundary.
        immutable auto login_return = m_data_store.user_login_token(login_params, raw_user_name, password);

        // NOTE: Be REALLY CAREFUL with the logic here as where things block, re-enter, state changes
        // and so on creates a variety of races and other weirdness that all tend to center around this
        // function. Highly recommend heavily testing any changes with extra latency inserted on various
        // operations (via sleep() or otherwise).
        // TODO: There are still weird issues potentially like a guest being logged in then someone
        // registering that name... that one we should probably try and handle better.
        if (login_return.success)
        {
            int user_id = login_return.user_id;
            if (login_return.guest)
            {
                // Should have been handled by the logic above, but just in case!
                if (!m_config.allow_guests)
                    throw new BadUserNamePasswordException(raw_user_name);

                user_id = generate_unique_guest_id();
            }
            else // Registered user
            {
                // Sanity check on ID
                if (login_return.user_id >= first_guest_id)
                {
                    throw new ServerMessageException(server_message_type._user_not_logged_in_msg, 
                                                     "Internal error: invalid ID for registered user");
                }

                // Now *after*, check if there is a duplicate login since this could have happened while
                // we were blocked waiting for the data store.
                auto old_client = find_client(login_return.user_id);
                if (!old_client.isNull())
                {
                    // Ok we already know about this client and have a user_id assigned
                    log_message("Login: Found old %s client with user ID %s...",
                                old_client.guest ? "guest " : "", old_client.player_data.user_id);
                    
                    // Are we already handling a login process for this client? If so just bail.
                    if (!old_client.is_login_allowed())
                        throw new DuplicateClientException(old_client.user_id);

                    // Kick out the old user. This allows us to handle orphaned connections or logon from
                    // another location better than not allowing login.                    
                    // NOTE: We need to temporarily prevent this client from trying to log in/join a room
                    // or else we can potentially get some strange races. Once we have confirmed to have kicked
                    // the client out of all the rooms we can safely remove it.
                    old_client.disallow_login();
                    kick_client_from_rooms(old_client.user_id);
                    m_clients.remove(old_client.user_id);
                }
            }

            // By this point we should be guaranteed that the user is not logged in
            assert(!(user_id in m_clients));

            // Create new client structure
            auto client = new LoggedInClient();
            client.m_player_data.guest = login_return.guest;
            client.m_player_data.user_id = user_id;
            client.m_player_data.order_id = -1;
            client.m_player_data.nick_name = login_return.nick_name;
            client.m_player_data.team_name = login_return.team_name;
            client.m_player_data.primary_color = login_return.primary_color;
            client.m_player_data.secondary_color = login_return.secondary_color;
            client.m_player_data.coat_of_arms_bitmap_index = cast(byte)login_return.coat_of_arms_bitmap_index;
            client.m_player_data.game_version = game_version;
            client.m_player_data.build_number = build_number;
            client.m_player_data.ip_address = ip_address;
            client.m_authentication_token[] = generate_unique_authentication_token(user_id)[];

            m_clients[client.user_id] = client;

            log_message("Login: Adding %s client ID %d (%d clients total)",
                        client.guest ? "guest " : "", client.user_id, m_clients.length);

            return client;
        }
        else
        {
            if (login_return.banned)
                throw new BannedUserException(raw_user_name, login_return.banned_reason);
            else
            {
                // Newer clients have a special message for if it was an attempted guest login, but username is taken
                // Bit messy logic but eventually want to move guest logins into something more explicit
                if (build_number >= 428 && password.empty)
                    throw new GuestNameTakenException(raw_user_name);
                else
                    throw new BadUserNamePasswordException(raw_user_name);
            }
        }
    }


    // Cleanup routine that gets called every once in a while
    // Gets rid of records for clients that have not been connected for a while to free
    // up some memory, invokes garbage collector explicitly, etc.
    private void cleanup()
    {
        scope(exit) log_message("Login: ERROR, cleanup task exited!");

        auto cleanup_ids = appender!(int[])();

        for (;;)
        {
            sleep(cleanup_timer_period);
            
            // Remove clients who we haven't seen for a while
            
            // There are a variety of strategies for doing this, but we'll pick a fairly simple
            // one: randomness! Pick some number of clients at random and check if they are still
            // around. As long as we do this "enough", we'll avoid too much memory bloat on average.

            // NOTE: The remove function blocks so we have to be a little careful as the client list
            // can change on the fly here... luckily it's harmless to "attempt" to remove a client
            // who has just logged on or similar, so we can just determine the IDs we want to check
            // up front.

            //log_message("Login: Starting cleanup (%s clients total)...", m_clients.length);

            immutable int number_to_cleanup = min(m_clients.length, cleanup_max_clients);
            cleanup_ids.clear();
            cleanup_ids.put(randomSample(m_clients.keys, number_to_cleanup));
            remove_clients_if_disconnected(cleanup_ids.data());

            //log_message("Login: Finished cleanup (%s clients total)...", m_clients.length);
        }
    }

    // HTTP
	private void http_error_page(HTTPServerRequest req,
							     HTTPServerResponse res,
							     HTTPServerErrorInfo error)
	{
		// TODO: In Debug mode, expose a stack trace?
		res.writeBody("Not found");
	}

	private void http_status_json(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
        auto status = public_status_query();
        res.writeJsonBody(status);
	}

    // Query server status (used by HTTP server, etc)
    private PublicServerStatus public_status_query() const
    {
        // TODO: Cache/throttle this...
        // TODO: Async?
        auto rooms = appender!(PublicRoomStatus[])();
        rooms.put(m_room_server.get_public_status());

        auto result = new PublicServerStatus;
        result.rooms = rooms.data();

        return result;
    }

    public Client queryClientForRoomJoin(authentication_token_type token)
    {
        // Check if the client is logged in and allowed to join rooms
        auto client = find_client(token);
        if (client.isNull())
            throw new NotLoggedInException();
        if (!client.is_login_allowed())
            throw new DuplicateClientException(client.user_id);

        // TODO: We could ensure that they come from the same host address as the original login
        // Obviously port can differ, but the IP address probably should not

        // Mark them as having been seen now
        client.reset_seen();

        // Kick them out of any rooms they are currently in
        // This is always legit since the authentication tokens match, etc.
        kick_client_from_rooms(client.user_id);

        // Now we're good to let them join the room
        return client;
    }

    public @property DataStoreInterface data_store()
    {
        return m_data_store;
    }

    // Const is fine, as the metaserver API class is pretty much immutable once created
    @property public pure nothrow ref const(MetaserverConfig) config() const { return m_config; }

    // Server info
    private MetaserverConfig m_config;

    private DataStoreInterface m_data_store;

    private int m_next_guest_id;
    private Regex!char m_strip_modifiers_regex;

    RoomServer m_room_server;

    private class LoggedInClient : Client
    {
        this()
        {
            m_last_seen.reset();
            m_last_seen.start();
        }

        // NOTE: These work together, so naively querying "disconnected" without first pinging the
        // room servers will produce unexpected results, since it's just a pure timer.
        public void reset_seen()         { m_last_seen.reset(); }
        public auto disconnected() const { return to!Duration(m_last_seen.peek()) > client_disconnected_timeout; }

        public pure nothrow void disallow_login() { m_login_allowed = false; }
        public pure nothrow bool is_login_allowed() const { return m_login_allowed; }

        private StopWatch m_last_seen;
        // Flag to disallow login/room join - we need this to prevent some potential races during
        // the login process if someone tries to log in from multiple locations at once, etc.
        private bool m_login_allowed = true;
    }

    private LoggedInClient[int] m_clients; // UserID -> Client info
};
