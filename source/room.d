module room;

import exceptions;
import room_client;
import room_connection;
import myth_socket;
import game;
import log;
import login_server;
import room_server;
import metaserver_config;
import private_api;

import std.datetime;
import std.stdio;
import std.conv;
import std.exception;
import std.string;
import std.array;
import std.typecons;

import vibe.vibe;

enum PlayerVerb
{
    add = 0,
    remove,
    change
};

enum GameVerb
{
    add = 0,
    remove,
    change
};

enum
{
    _player_is_administrator_flag     = 1 << 0, // Weird "myth myth myth" background to player row...?
    _player_is_anonymous_flag         = 1 << 1, // Seems unused
    _player_is_bungie_caste_icon_flag = 1 << 2, // Forces icon to "Admin"... not really necessary; can set directly
};

struct metaserver_game_aux_data
{
    int room_game_id;
    uint host; // IPV6 PROBLEM
    ushort port;
    byte verb;
    byte game_version;
    int seconds_remaining;
    int creating_player_id;
    short game_data_size;
    short unused_short;
    int[2] unused;
};
static assert (metaserver_game_aux_data.sizeof == 32);


/***
* Stores and manages all the state of the server and rooms
*
* NOTE: Currently we handle waking fibers on send activity at the room level instead of the individual
* connection/client level. This is mostly a work-around for issues with the garbage collector and libevent
* in vibe which causes accesses to freed data and other badness. By having a single event for each room
* which persists for the entire life of the server process we sidestep the issue.
*
* This is somewhat inefficient in that even if we enqueue a packet to a single client we still wake
* all of the room's fibers up to check their send queues, which is non-ideal. That said, given the size
* of rooms (<100 people) and the frequency of sends right now (quite low), it's not a critical problem.
* Future support for things like live streaming film data to clients might change this a bit, but even
* then we're probably not going to be CPU-limited so it's not a huge deal.
*/
class Room
{
    public this(LoginServer login_server, RoomServer room_server, string room_name,
                room_info info, int maximum_clients)
    {
        m_login_server = login_server;
        m_room_server = room_server;
        m_room_info = info;
        m_room_name = room_name;
        m_maximum_clients = maximum_clients;

        // Set up dot commands
        m_dot_commands["time"] = &dot_time;
        m_dot_commands["games"] = &dot_games;
        m_dot_commands["proxy"] = &dot_proxy;
        m_dot_commands["help"] = &dot_help;
        m_admin_dot_commands["info"] = &dot_info;
        m_admin_dot_commands["kick"] = &dot_kick;
        m_admin_dot_commands["ban"] = &dot_ban;
        m_admin_dot_commands["message"] = &dot_message;

        // Set up listen socket for this room
        listenTCP(m_room_info.port, &handle_connection, "0.0.0.0");

        log_message("%s: Created with ID %s on port %s (max %d clients)",
                    m_room_name, m_room_info.room_id, m_room_info.port, m_maximum_clients);
    }

    // Launched in a new fiber when a new login connection is made to the server
    private void handle_connection(TCPConnection stream)
    {
        auto connection = new RoomConnection(m_login_server, this);
        connection.run(stream);
    }

    // Message will be split by lines (\n). Blank lines ignored.
    public void send_blue_message(RoomConnection connection, string message)
    {
        foreach (line; splitLines(message))
        {
            if (!line.empty)
                connection.send_packet(packet_type._message_of_the_day_packet, line);
        }
    }
    // Same as above, but send to whole room
    private void send_blue_message(string message)
    {
        foreach (line; splitLines(message))
        {
            if (!line.empty)
                send_packet_to_all_clients(packet_type._message_of_the_day_packet, MythSocket.encode_payload(line));
        }
    }

    // Also if we fail to contact the metaserver for something like this we may or may not want the
    // exception to be thrown in the fiber that triggered it, so do some thinking/testing...
    private void update_room_data()
    {
        m_room_info.player_count = cast(short)this.player_count();
        m_room_info.game_count   = cast(short)this.game_count();
        // NOTE: Could check if it's really dirty/changed, but always mark it for now in case
        // the client is somehow out of sync.
        m_room_server.set_room_data_dirty();
    }

    public void add_connection(RoomConnection connection)
    {
        if (m_connections.length >= m_maximum_clients)
            throw new TooManyClientsException();

        auto client = connection.client;

        // NOTE: Should never really get two clients with the same ID, but just to be sure
        if (client.user_id in m_connections)
            throw new DuplicateClientException(client.user_id);

        // Add new client to the room
        m_connections[client.user_id] = connection;
        log_message("%s: Added client ID %d (%d connections total)",
                    m_room_name, client.user_id, m_connections.length);

        // Sync new player to all clients
        send_packet_to_all_clients(packet_type._player_list_packet, encode_player_payload(client, PlayerVerb.add));

        send_full_room_update_to_client(connection);
        update_room_data();

        // Finally do any join room actions (blue bar, etc)
        // NOTE: This blocks, so can be dangerous... be careful with login/room races!
        // Eventually it might make it more predictable to do this by the room connection after they have
        // entered their main packet loop, since the HTTP server has no notion of current state and thus can't
        // handle races properly. For now it's ok since add_connection is the last thing that the room connection
        // does and this is the last thing we do *after* already adding them to our connected list.        
        auto message = m_login_server.data_store.get_join_room_message(connection.client.guest);
        send_blue_message(connection, message);
    }

    public void remove_connection(RoomConnection connection)
    {
        auto client = connection.client;

        if (!find_client_in_room(client.user_id).isNull())
        {
            // First remove client from our list to avoid sending the following packets
            m_connections.remove(client.user_id);
            log_message("%s: Removed client ID %d (%d connections total)",
                        m_room_name, client.user_id, m_connections.length);

            // Remove any games they were hosting
            auto game = connection.visible_hosted_game;
            if (game) remove_game(game);

            // Sync player deletion to all remaining clients
            send_packet_to_all_clients(packet_type._player_list_packet, encode_player_payload(client, PlayerVerb.remove));
        }

        // Update server room list metadata
        update_room_data();
    }

    // Call after changing player data or similar to synchronize with the other players in the room
    public void send_client_update(in RoomClient client)
    {
        send_packet_to_all_clients(packet_type._player_list_packet, encode_player_payload(client, PlayerVerb.change));
    }

    // NOTE: We don't currently track games directly here (we simply searched for hosted games in
    // our users list where necessary) but we need to send updates to the whole room as appropriate
    private int game_count() const
    {
        int games = 0;
        foreach (connection; m_connections)
            if (connection.visible_hosted_game)
                ++games;
        return games;
    }

    public void add_game(Game game)
    {
        send_packet_to_all_clients(packet_type._game_list_packet, encode_game_payload(game, GameVerb.add));
        update_room_data();

        log_message("%s: Added game hosted by user ID %d", m_room_name, game.host_user_id);
    }

    public void update_game(Game game)
    {
        send_packet_to_all_clients(packet_type._game_list_packet, encode_game_payload(game, GameVerb.change));
    }

    public void remove_game(const(Game) game)
    {
        send_packet_to_all_clients(packet_type._game_list_packet, encode_game_payload(game, GameVerb.remove));
        update_room_data();

        log_message("%s: Removed game hosted by user ID %d", m_room_name, game.host_user_id);
    }

    public void send_full_room_update_to_client(RoomConnection target_connection)
    {
        // Shouldn't ever get called if the connection isn't in the same room
        // Construct lists
        ubyte[] player_payload;
        ubyte[] game_payload;
        foreach (user_id, connection; m_connections)
        {
            // Players
            auto new_player_payload = encode_player_payload(connection.client, PlayerVerb.add);
            
            // Split into multiple packets if these are getting too big
            if (new_player_payload.length + player_payload.length > (MAXIMUM_PACKET_SIZE - 100))
            {
                target_connection.send_packet_payload(packet_type._player_list_packet, player_payload.idup);
                player_payload.length = 0;
            }
            player_payload ~= new_player_payload;

            // Games
            auto game = connection.visible_hosted_game;
            if (game)
            {
                auto new_game_payload = encode_game_payload(game, GameVerb.add);
            
                if (new_game_payload.length + game_payload.length > (MAXIMUM_PACKET_SIZE - 100))
                {
                    target_connection.send_packet_payload(packet_type._game_list_packet, game_payload.idup);
                    game_payload.length = 0;
                }
                game_payload ~= new_game_payload;
            }
        }

        if (player_payload.length > 0)
            target_connection.send_packet_payload(packet_type._player_list_packet, player_payload.idup);
        if (game_payload.length > 0)
            target_connection.send_packet_payload(packet_type._game_list_packet, game_payload.idup);
    }

    /***
    * Does not make a copy of the input parameter! i.e. a reference to the payload will sit in the
    * client send queues until it eventually gets garbage collected.
    * If the caller wishes to modify it after calling this function it must be duplicated externally.
    * This makes the regular case (construct payload, then ditch it) more efficient.
    */
    public void send_packet_to_all_clients(packet_type type, immutable(ubyte)[] payload)
    {
        foreach (user_id, connection; m_connections)
            connection.send_packet_payload(type, payload);
    }

    /**
    * Returns true if the given user is in the room and the message was sent successfully.
    */
    public bool send_packet_to_client(int target_user_id, packet_type type, in ubyte[] payload)
    {
        auto connection = target_user_id in m_connections;
        if (connection)
        {
            connection.send_packet(type, payload);
            return true;
        }
        return false;
    }

    /**
    * This now needs specialization for each client so it needs a specific entry point
    */
    public void send_room_list_to_all_clients(const(room_info)[] room_list)
    {
        foreach (connection; m_connections)
        {
            auto client_room_list = specialize_room_list_for_client(connection.client, room_list);
            connection.send_packet(packet_type._room_list_packet, client_room_list);
        }
    }

    public GameResultReturn report_game_result(GameResult game_result)
    {
        auto result = m_login_server.data_store.add_game_result(game_result);
        return result;
    }

    // Execute a dot command from a given player with optional "target" player 
    public void dot_command(string command,
                            string params,
                            RoomConnection caller,
                            bool target_user_valid, int target_user_id)
    {
        // If necessary, look up target connection in the room
        Nullable!RoomConnection target;
        if (target_user_valid)
        {
            auto target_connection = target_user_id in m_connections;
            if (target_connection)
                target = *target_connection;
        }

        // Standard dot command?
        auto dg = command in m_dot_commands;
        if (dg)
        {
            (*dg)(caller, target, params);
            return;
        }
        
        // Admin command?
        dg = command in m_admin_dot_commands;
        if (dg)
        {
            // Check for admin permissions
            if (m_login_server.data_store.get_user_admin_level(caller.client.user_id) > 0)
            {
                (*dg)(caller, target, params);
                return;
            }
            else
            {
                log_message("%s: Client ID %d is not allowed to use admin command '%s'!",
                            m_room_name, caller.client.user_id, command);
            }
        }

        // Nothing handled it... let the user know
        send_blue_message(caller, format("Unknown command '%s'.", command));
    }

    private void dot_time(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        auto dt = Clock.currTime();
        auto message = format("The current server time is %04d-%02d-%02d %02d:%02d:%02d %s.",
                      dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second,
                      dt.dstInEffect ? dt.timezone.dstName() : dt.timezone.stdName);

        send_blue_message(caller, message);
    }

    private void dot_games(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        // Collect game info from the current room
        string text;
        foreach (connection; m_connections)
        {
            auto game = connection.visible_hosted_game;
            if (game)
            {
                string game_name;
                string map_name;
                auto desc = game.decode_game_info(game_name, map_name);

                string game_string = format("'%s|p', %d/%d, |iHost:|p '%s|p'%s",
                                            game_name, 
                                            desc.player_count, desc.parameters.maximum_players,
                                            connection.client.player_data.nick_name,
                                            // Good enough test of whether it's proxied for now...
                                            game.host_address_ipv4 == connection.remote_address_ipv4 ? "" : " |i(proxied)|p");

                // Only show elapsed time if the game is currently in progress
                int elapsed = game.elapsed_time_seconds();
                if (elapsed > 0)
                {
                    int hours = elapsed / 3600;
                    elapsed -= hours * 3600;
                    int minutes = elapsed / 60;
                    elapsed -= minutes * 60;
                    int seconds = elapsed;

                    if (hours > 0)
                        game_string ~= format(", |iElapsed:|p %d:%02d:%02d", hours, minutes, seconds);
                    else
                        game_string ~= format(", |iElapsed:|p %d:%02d", minutes, seconds);
                }

                text ~= game_string ~ "\n";
            }
        }

        if (text.length == 0)
            text = "No games are currently hosted in this room.\n";

        send_blue_message(caller, text);
    }

    private void dot_help(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        send_blue_message(caller, "Available commands:\n.help .games .proxy .time .userid .version");
    }

    private void dot_proxy(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        // Optional parameters - "on/off" for now
        string action = "";

        if (params == "on")
            caller.client.set_host_proxy_state(ClientHostProxyState.on);
        else if (params == "off")
            caller.client.set_host_proxy_state(ClientHostProxyState.off);

        if (params == "unknown")
            caller.client.set_host_proxy_state(ClientHostProxyState.unknown);

        auto host_proxy_state = caller.client.host_proxy_state;
        string message =
            format("Your host proxy setting is: |i%s|p\n",
                   host_proxy_state == ClientHostProxyState.on ? "on" :
                   host_proxy_state == ClientHostProxyState.off ? "off" :
                   "unknown");

        send_blue_message(caller, message);
    }

    private void dot_info(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        if (target.isNull)
        {
            send_blue_message(caller, "You must first select a player by clicking on their name.");
            return;
        }

        auto data = target.client.player_data;
        auto message = format("'%s'|p, |iID:|p %s, |iVersion:|p %s build %s, |iIP:|p %s",
                              data.nick_name, data.user_id, data.game_version, target.client.build_number, data.ip_address);

        send_blue_message(caller, message);
    }

    private void dot_kick(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        if (target.isNull)
        {
            send_blue_message(caller, "You must first select a player by clicking on their name.");
            return;
        }

        auto exception = new ClientKickedException(target.client.user_id, caller.client.user_id, params);
        // NOTE: if this was a "server message" instead of a separate packet we could just do the
        // server message exception below... not clear why there are two different types of packets.
        target.send_packet(packet_type._you_just_got_blammed_sucka_packet, exception.msg);
        // Kill their connection with an exception in their task
        target.throw_exception_in_task(exception);
    }

    private void dot_ban(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        if (target.isNull)
        {
            send_blue_message(caller, "You must first select a player by clicking on their name.");
            return;
        }

        // Optional parameters: days (int) for now
        // TODO: Allow them to provide a reason too
        int days = 7;
        string reason = "";

        if (params.length > 0)
        {
            try { days = to!int(params); }
            catch (Exception e)
            {
                // Ignore conversion errors... use default
            }
        }
        
        if (target.client.guest)
        {
            send_blue_message(caller, "Cannot ban a guest. Kicking instead...");
        }
        else
        {
            m_login_server.data_store.ban_user(target.client.user_id, days, reason);
            string message = "Player '" ~ target.client.player_data.nick_name ~ "' ID " ~ to!string(target.client.user_id) ~ " banned for " ~ to!string(days) ~ " days";
            log_message("%s: %s", m_room_name, message);
            send_blue_message(caller, message);
        }

        dot_kick(caller, target, reason);
    }

    private void dot_message(RoomConnection caller, Nullable!RoomConnection target, string params)
    {
        if (target.isNull)
            send_blue_message(params);
        else
            send_blue_message(target.get(), params);
    }

    private immutable(ubyte)[] encode_player_payload(in RoomClient client, PlayerVerb verb) const
    {
        int caste_icon = client.caste_bitmap_index(this.room_type);
        auto player_data = client.player_data_big_endian();

        metaserver_player_aux_data aux_data_packet;
        aux_data_packet.verb = cast(ushort)verb;
        aux_data_packet.flags = 0;
        aux_data_packet.ranking = 0;
        aux_data_packet.player_id = client.user_id;
        aux_data_packet.room_id = 0; // NOTE: Unused in bungie metaserver
        aux_data_packet.caste = cast(short)caste_icon;
        aux_data_packet.player_data_length = cast(short)player_data.length;
        aux_data_packet.order = client.order_id;

        return MythSocket.encode_payload(aux_data_packet, player_data);
    }

    private static immutable(ubyte)[] encode_game_payload(in Game game, GameVerb verb)
    {
        auto game_data = game.game_data_big_endian();

        metaserver_game_aux_data aux_data_packet;

        // host_user_id is used as the room game ID, since it has to be unique anyways
        // TODO: Could move this part of the packet construction to Game itself
        aux_data_packet.room_game_id = game.host_user_id;
        aux_data_packet.host = game.host_address_ipv4();
        aux_data_packet.port = game.host_port();
        aux_data_packet.verb = cast(byte)verb;
        aux_data_packet.game_version = 0;
        aux_data_packet.seconds_remaining = game.time_remaining_seconds();
        aux_data_packet.creating_player_id = game.host_user_id;
        aux_data_packet.game_data_size = cast(ushort)game_data.length;
        
        // Debug
        //log_message("encode_game_payload: ID %s, host %s, port %s, verb %s", aux_data_packet.room_game_id, 
        //			aux_data_packet.host, aux_data_packet.port, aux_data_packet.verb);

        return MythSocket.encode_payload(aux_data_packet, game_data);
    }

    // Query public server status (used by HTTP server, etc)
    PublicRoomStatus query_public_status() const
    {
        auto result = new PublicRoomStatus;
        result.id = this.room_id;
        result.name = m_room_name;
        result.type = this.room_type;

        foreach (connection; m_connections)
        {
            auto client = connection.client;

            // Maps fairly 1:1 to player data, but omits some private fields
            PublicRoomStatus.Player player_status;
            player_status.guest = client.guest;
            player_status.user_id = client.user_id;
            player_status.nick_name = client.player_data.nick_name;
            player_status.primary_color = client.player_data.primary_color;
            player_status.secondary_color = client.player_data.secondary_color;
            player_status.in_game = client.in_game;
            result.players ~= player_status;

            auto game = connection.visible_hosted_game;
            if (game)
            {
                string game_name;
                string map_name;
                auto desc = game.decode_game_info(game_name, map_name);

                PublicRoomStatus.Game game_status;
                game_status.name = game_name;
                game_status.map_name = map_name;
                game_status.scoring_name = game_scoring_names[desc.parameters.scoring];
                game_status.host_user_id = client.player_data.user_id;
                game_status.players = desc.player_count;
                game_status.max_players = desc.parameters.maximum_players;
                game_status.elapsed_seconds = game.elapsed_time_seconds();
                
                result.games ~= game_status;
            }
        }
        return result;
    }

    public pure nothrow Nullable!RoomConnection find_client_in_room(int user_id)
    {
        auto connection = (user_id in m_connections);
        return connection ? Nullable!RoomConnection(*connection) : Nullable!RoomConnection();
    }

    public int player_count() const { return cast(int)m_connections.length; }
    public pure nothrow const(room_info) get_room_info() const { return m_room_info; }

    @property public pure nothrow ref const(MetaserverConfig) config() const { return m_room_server.config(); }

    // Convenience
    @property public pure nothrow int room_id() const { return m_room_info.room_id; }
    @property public pure nothrow RoomType room_type() const { return m_room_info.room_type; }
    @property public pure nothrow int maximum_clients() const { return m_maximum_clients; }
    @property public pure nothrow RoomServer room_server() { return m_room_server; }
        
    private LoginServer m_login_server;
    private RoomServer m_room_server;
    
    private string m_room_name;
    private room_info m_room_info;
    private immutable(int) m_maximum_clients;

    private alias void delegate(RoomConnection, Nullable!RoomConnection, string)[string] DotCommandMap; 
    private DotCommandMap m_dot_commands;
    private DotCommandMap m_admin_dot_commands;

    // A list of all the clients connected to the room, keyed on user ID
    private RoomConnection[int] m_connections;
};
