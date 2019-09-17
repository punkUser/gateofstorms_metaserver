module room_connection;

import room_client;
import exceptions;
import myth_socket;
import connection;
import room;
import game;
import game_recording;
import mac_roman;
import log;
import room_server;
import login_server;
import private_api;

import vibe.core.core;
import vibe.core.path;
import vibe.core.concurrency;
import vibe.core.net;
import vibe.core.file;

import std.algorithm;
import std.container;
import std.socket;
import std.stdio;
import std.conv;
import std.array;
import std.ascii;
import std.variant;
import std.datetime;
import std.file;
import core.memory;

// TODO: Come up with some sort of great solution here
// This is definitely a weird trade-off... if we make this send queue too small then it is actually
// possible to blow it, although usually under synthetic scenarios like load test scripts.
// If you blow the send queue you can miss messages about users joining/leaving and so on and the
// client can get out of sync; there's not currently a good way to get them back in sync although
// they can always rejoin the room if desired.
// That said, setting it too high can cause high memory use, which is not desirable either. Thus
// we need some sort of middle ground, even if it's a little glitchy with the load testing scripts.
immutable size_t send_message_queue_size = 100;

private immutable host_connection_test_timeout = 3.seconds;


private enum player_mode
{
    listening = 0,
    deaf,
    NUMBER_OF_PLAYER_MODES
};

private struct game_search_query
{
    short s_game_type;
    short s_game_scoring;
    short veterans;
    short unit_trading;
    short teams;
    short alliances;
    short enemy_visibility;
    short unused;
};

private struct myth_metaserver_chat_packet
{
    short type;
    short length;
    rgb_color color;
    ushort flags;
    ushort pad;
    uint player_id;
    uint selected_player_id;
};

private struct room_login_successful_packet
{
    uint user_id;
    short maximum_players_per_room;
    short unused;
};

// Stores packets waiting to be sent to the client
private struct pending_packet
{
    packet_type type;
    const(ubyte[]) payload;
};

private struct game_score_packet
{
    uint room_game_id;
    bungie_net_game_standings standings;
};

struct start_game_packet
{
    int game_time_in_seconds;
    int[2] unused;
};



final class RoomConnection : Connection
{
    // NOTE: Must always be constructed on the fiber that owns the connection
    public this(LoginServer login_server, Room room)
    {
        super();
        m_login_server = login_server;
        m_room = room;
        m_client_deaf = false;
    }

    protected override void run_internal(MythSocket socket)
    {
        m_main_task = Task.getThis();
        m_remote_address_ipv4 = socket.remote_address_ipv4;

        socket.negotiate_session_key();

        // Receive login packet
        string user_name_unused;
        authentication_token_type token;
        socket.receive_packet(packet_type._room_login_packet, token, user_name_unused);

        // Receive player data packet
        // We make this "optional" since we don't actually use it in this server
        try
        {
            metaserver_player_data player_data;
            string nick_name, team_name;
            socket.receive_packet(packet_type._set_player_data_packet, player_data, nick_name, team_name);

            // NOTE: We don't currently use this data at all.
            // We always rely on the data that we exchanged during login to avoid any sort of room spoofing.
        }
        catch (UnexpectedPacketTypeException e) {}

        // Ok, now set up the send queue/task for broadcasts to this user
        m_send_task = runTask({
            try
            {
                while (socket.connected) // "connected" is the appropriate check for *sending*
                {
                    receive((packet_type type, immutable(ubyte)[] payload)
                            {
                                socket.send_packet_payload(type, payload);
                            },
                            // Should never send anything other than the above mesage
                            (Variant v)
                            { 	
                                log_message("INTERNAL ERROR: Unknown message type in send packet task!");
                                assert(false);
                            });
                    // No yield for now... it's important to drain these outgoing queues quickly so
                    // we want to avoid a lot of fiber switch thrash.
                    // That said, fairness might be a better policy here... hard to say.
                }
            }
            catch (Exception e)
            {
                // We mostly ignore exceptions here and allow the task to terminate normally.
                // There may be cases where this is bad, but the only real exceptions we expect to
                // see are the caller interrupting us, or perhaps socket exceptions. Both of
                // which we basically just want to terminate gracefully.
            }
        });
        // Make sure it never out-lives this function
        scope(exit) {
            if (m_send_task.running) m_send_task.interrupt();
        }
        
        try
        {
            // Look up user
            // NOTE: Important not to block between here and adding the user to the room or else two room
            // joins could race! Hence why we do this after we've received all of the relevant data from the client.
            auto client_info = m_login_server.queryClientForRoomJoin(token);
            m_client = new RoomClient(client_info);

            // Reject guests in ranked/tourney rooms
            // NOTE: This doesn't produce a really nice error message in the client, but it will at least go back
            // to whatever room they were in, try a new one, etc.
            if (!is_client_allowed_in_room(m_client, m_room.get_room_info()))
                throw new NotAllowedInRoomException(m_client.user_id);

            // Enqueue messages
            // WARNING: If these were to block, we'd have an issue... could add them to the send queue instead
            // Send back login successful packet
            room_login_successful_packet room_login_successful;
            room_login_successful.user_id = m_client.user_id;
            room_login_successful.maximum_players_per_room = cast(ushort)m_room.maximum_clients();
            send_packet(packet_type._room_login_successful_packet, room_login_successful);

            // Also send a server message (not clear why this is necessary, but that's how the original does it)
            send_packet(packet_type._server_message_packet, MythSocket.encode_server_message_payload(server_message_type._login_successful_msg));

            // And add ourselves to the room
            scope(exit) m_room.remove_connection(this);
            m_room.add_connection(this); // NOTE: Blocks due to triggering data store operations
        
            run_packet_loop(socket);
        }
        catch (InterruptException e)
        {
            log_message("Caught InterruptException: %s", e.msg);

            // Another fiber interrupted us for some reason. Check if we have a pending
            // exception that they want us to throw in this thread.
            if (m_pending_exception)
            {
                auto pending = m_pending_exception;
                m_pending_exception = null;
                throw pending;
            }
        }
    }

    private void run_packet_loop(MythSocket socket)
    {
        while (!socket.empty) // "empty" is the appropriate check for *receiving*
        {
            // Handle incoming packet
            auto header = socket.peek_packet_header();

            version (DebugPackets)
            {
                debug log_message("%s: Received %s", m_client.user_id, header.type);
            }

            switch (header.type)
            {
                case packet_type._recording_stream_header_packet:
                    handle_recording_stream_header(socket);
                    break;

                case packet_type._recording_stream_command_packet:
                    handle_recording_stream_command(socket);
                    break;

                case packet_type._recording_stream_end_packet:
                    handle_recording_stream_end(socket);
                    break;

                case packet_type._room_broadcast_packet:
                case packet_type._directed_data_packet:
                    handle_chat(socket, header.type);
                    break;

                case packet_type._game_search_query_packet:
                    handle_game_search_query(socket);
                    break;

                case packet_type._buddy_query_packet:
                    handle_buddy_query(socket);
                    break;

                case packet_type._order_query_packet:
                    handle_order_query(socket);
                    break;

                case packet_type._create_game_packet:
                    handle_create_game(socket);
                    break;

                case packet_type._remove_game_packet:
                    handle_remove_game(socket);
                    break;

                case packet_type._game_player_list_packet:
                    handle_game_player_list(socket);
                    break;

                case packet_type._game_score_packet:
                    handle_game_score(socket);
                    break;

                case packet_type._reset_game_packet:
                    handle_reset_game(socket);
                    break;

                case packet_type._start_game_packet:
                    handle_start_game(socket);
                    break;

                case packet_type._request_full_update_packet:
                    socket.receive_packet(packet_type._request_full_update_packet); // Null payload
                    m_room.send_full_room_update_to_client(this);
                    break;

                case packet_type._set_player_mode_packet:
                    handle_player_mode(socket);
                    break;

                case packet_type._set_player_data_packet:
                    handle_player_data(socket);
                    break;

                case packet_type._player_info_query_packet:
                    handle_player_info_query(socket);
                    break;

                case packet_type._update_player_information_packet:
                    handle_update_player_info(socket);
                    break;

                case packet_type._keepalive_packet:
                    // This already triggers a reset of our read timeout, so no need to do anything special here.
                    socket.receive_packet_payload();
                    break;

                default:
                    log_message("**** Packet %s unimplemented ****", header.type);
                    socket.receive_packet_payload(); // Ignore packet
                    break;
            }

            // DEBUG: This has high overhead but helps us track down issues closer to where they actually happen
            version (DebugGC)
            {
                // Ensure there is no way this makes it into a release build.
                debug GC.collect();
            }

            // TODO: Explode if send task is not still running, etc?

            // Be a little more fair even if we are a high traffic connection
            vibe.core.core.yield();
        }
    }

    /***
    * Enqueues a packet to be sent to this user with the given type and payload
    *
    * NOTE: This function will often be called from another fiber, i.e. not the one that owns this connection.
    * Thus we must simply enqueue it and signal the owning fiber that data is ready for sending. Trying to
    * send it directly from the calling fiber could cause races or allow misbehaved client behavior to
    * propogate to other clients (i.e. via blocking due to send buffer overflow).
    */
    public void send_packet_payload(packet_type type, immutable(ubyte)[] payload)
    {
        if (m_send_task && m_send_task.running)
        {
            // TODO: Handle mailbox overflow... for now it's set to just ignore, but needs a proper solution
            if (!m_client_deaf)
            {
                m_send_task.send(type, payload);
            }
        }
        else
        {
            // Uhh... presumably this is badness and we need to let our receive task know, but
            // we probably shouldn't get here without the receive task figuring it out too.
            log_message("%s: Error sending packet %s! Send task not running?", m_client.user_id, type);
        }
    }

    public void send_packet(T...)(packet_type type, T params)
    {
        send_packet_payload(type, MythSocket.encode_payload(params));
    }

    public void throw_exception_in_task(Exception e)
    {
        // If the caller here is not the right task, we need to interrupt/wake up the right one		
        if (m_main_task != Task.getThis())
        {
            // If there's already a pending exception, just ignore this one
            if (!m_pending_exception)
                m_pending_exception = e;
            m_main_task.interrupt(); // throws an "InterruptException" in the main thread
        }
        else
        {
            // Otherwise it's just a regular throw in the current task
            throw e;
        }
    }


    // Lobby-related packets
    //---------------------------------------------------------------------------------------------

    // Handle broadcasts and private messages
    private void handle_chat(MythSocket socket, short type)
    {
        uint target_user_id;
        int local_echo;
        myth_metaserver_chat_packet chat_packet;
        string player_name;
        string message;

        bool broadcast;
        switch (type)
        {
            case packet_type._room_broadcast_packet:
                socket.receive_packet(packet_type._room_broadcast_packet, chat_packet, player_name, message);
                broadcast = true;
                break;

            case packet_type._directed_data_packet:
                socket.receive_packet(packet_type._directed_data_packet, target_user_id, local_echo, chat_packet, player_name, message);
                broadcast = false;
                break;

            default:
                // Shouldn't have called this function for other packet types
                assert(false);
        }

        // Check if this is a command rather than a chat message
        // Dot commands start with '.' and are followed by some alphabetic character after it [a-z/A-Z]
        if (message.length > 1 && message[0] == '.' && isAlpha(message[1]))
        {
            // Split the command from the params at the first space
            auto split_result = findSplit(message[1..$], " ");
            m_room.dot_command(split_result[0], split_result[2], this, !broadcast, target_user_id);
        }
        else
        {
            // Avoid chat spoofing
            // TODO: Perhaps replace RGB as well... at which point we might as well just replace the whole packet.
            player_name = m_client.player_data.nick_name;
            chat_packet.player_id = m_client.user_id;

            if (broadcast)
            {
                // Send the packet to everyone in the room
                auto payload = MythSocket.encode_payload(chat_packet, player_name, message);
                m_room.send_packet_to_all_clients(packet_type._room_broadcast_packet, payload);
            }
            else
            {
                // Otherwise send it just to the requested player
                // NOTE: Player ID and local_echo are unused by the client, but we'll pass on what the sender sent anyways.
                auto payload = MythSocket.encode_payload(target_user_id, local_echo, chat_packet, player_name, message);
                m_room.send_packet_to_client(target_user_id, packet_type._directed_data_packet, payload);

                // If requested, echo it back to the client as well
                if (local_echo && target_user_id != m_client.user_id)
                    send_packet(packet_type._directed_data_packet, payload);
            }
        }
    }

    private void handle_game_search_query(MythSocket socket)
    {
        game_search_query query;
        string game_name;
        string map_name;
        socket.receive_packet(packet_type._game_search_query_packet, query, game_name, map_name);

        //log_message("**** handle_game_search_query() : unimplemented ****");

        // TODO: Send the search request to the server and reply
        // For now just send an empty reply
        // Will eventually include an array of metaserver_game_aux_data structures
        send_packet(packet_type._game_list_pref_packet);
    }

    private void handle_buddy_query(MythSocket socket)
    {
        //log_message("**** handle_buddy_query() : unimplemented ****");
        socket.receive_packet_payload();
    }

    private void handle_order_query(MythSocket socket)
    {
        //log_message("**** handle_order_query() : unimplemented ****");
        socket.receive_packet_payload();
    }


    // Game-related packets
    // NOTE: For a bunch of these, each Myth client in a game will send their version (such as
    // endgame scores). For our purposes, we currently ignore any of these packets that were not
    // sent by the host of the game. We might want to change this policy for game scores in the
    // case that we don't get anything from the original host in case of "plug pulling".
    //---------------------------------------------------------------------------------------------
    private void handle_create_game(MythSocket socket)
    {
        ushort port;
        short order;
        ubyte[] game_data;
        socket.receive_packet(packet_type._create_game_packet, port, order, game_data);

        if (m_hosted_game)
        {
            // Already hosting, update game data
            m_hosted_game.update_game_data(game_data);
            m_room.update_game(m_hosted_game);
        }
        else
        {
            uint address_ipv4 = m_remote_address_ipv4;

            // Test direct connectivity to the host
            if (m_client.host_proxy_state == ClientHostProxyState.unknown)
            {
                log_message("Testing host connectivity for host ID %d...", m_client.user_id);

                // Need to test if the client is reachable from the outside
                // TODO: We should ideally handle the case where they stop hosting before we can
                // adequately determine if we can connect, i.e. by staying "unknown". That gets a bit
                // finicky though, so allowing it to block the room_connection fiber and fall back to proxy "on"
                // is a reasonable complexity compromise for now.
                try
                {
                    // Doesn't seem to be a timeout parameter on connectTCP... roll our own.
                    TCPConnection test_connection;
                    {
                        auto task = Task.getThis();
                        auto timer = setTimer(host_connection_test_timeout, {
                            task.interrupt();
                        });
                        scope(exit) timer.stop();
                        test_connection = connectTCP(socket.remote_address_string(), port);
                    }

                    // Debug "ghost" players in game lobby
                    //debug sleep(5.seconds);

                    test_connection.close();

                    log_message("Successfully connected to host ID %d: disabling host proxy", m_client.user_id);
                    m_client.set_host_proxy_state(ClientHostProxyState.off);
                }
                catch (Exception e)
                {
                    log_message("Failed to connect to host ID %d: enabling host proxy", m_client.user_id);
                    m_client.set_host_proxy_state(ClientHostProxyState.on);
                }
            }

            // If supported by the client and required, enable host proxy
            if (m_client.supports_host_proxies && m_client.host_proxy_state == ClientHostProxyState.on) 
            {
                // Acquire a host proxy, if available
                // Exceptions/errors here are non-critical... just don't enable the proxy
                try
                {
                    auto host_proxy = m_room.room_server.host_proxy.acquire(m_client.user_id);
                    address_ipv4 = host_proxy.address_ipv4;
                    port = host_proxy.port;
                    m_room.send_blue_message(this, "Your host does not appear to be joinable. Host proxy enabled.");
                }
                catch (Exception e)
                {
                    log_message(e.msg);
                }
            }

            m_hosted_game = new Game(m_room.room_type, m_client.player_data.user_id, address_ipv4, port, game_data);
            m_room.add_game(m_hosted_game);
        }
    }

    private void handle_remove_game(MythSocket socket)
    {
        socket.receive_packet(packet_type._remove_game_packet); // Null payload

        if (m_hosted_game)
        {
            // Weird, but "remove_game" below triggers an update_room_data which counts the number
            // of non-null "hosted_games" for all users, so it's important that we null this out
            // *before* calling remove_game so that the count will be correct.
            auto game = m_hosted_game;
            m_hosted_game = null;

            // Harmless if no proxy was assigned
            m_room.room_server.host_proxy.release(m_client.user_id);
            m_room.remove_game(game);
        }
    }

    private void handle_reset_game(MythSocket socket)
    {
        socket.receive_packet_payload();
        // Noop currently
    }

    private void handle_start_game(MythSocket socket)
    {
        // TODO: Could just ignore it instead
        if (!m_hosted_game)
        {
            throw new ClientProtocolException("Received start game packet, but user ID "
                                              ~ to!string(m_client.user_id) ~ " is not hosting a game");
        }

        start_game_packet start_game_data;
        socket.receive_packet(packet_type._start_game_packet, start_game_data);
        m_hosted_game.start(start_game_data.game_time_in_seconds);
    }

    private void handle_game_player_list(MythSocket socket)
    {
        // Player list is a game_id followed by an array of user_id's
        uint game_id;
        int[] user_ids;
        socket.receive_packet(packet_type._game_player_list_packet, game_id, user_ids);

        if (m_hosted_game)
        {
            // Get user-names associated with each ID from the server
            // We do this so that we can still record the names of players/guests at the time they
            // played a game (for scores), even if their guest ID is reused later.
            // We won't go as far as to record other information for now though.
            immutable(PlayerData)[] players;
            foreach (i, id; user_ids)
            {
                auto player = m_room.find_client_in_room(id);
                if (!player.isNull())
                    players ~= player.client.player_data;
            }
            m_hosted_game.update_player_list(players);
        }
        else
        {
            // Ignore player list from non-host for now
        }
    }

    private void handle_game_score(MythSocket socket)
    {
        // NOTE: Regular score packet now followed by variable-sized player payload
        game_score_packet game_score;
        bungie_net_game_standings_player[] players;
        
        socket.receive_packet(packet_type._game_score_packet, game_score, players);

        /*
        log_message("Game scores from user %s:", m_client.user_name);
        log_message("*********************************************************");
        log_message(game_score.standings);
        log_message("*********************************************************");
        */

        // Only use the hosts's score report currently
        // NOTE: This technically allows the host to "pull the plug" or similarly exploit before the
        // game is over and the results have been submitted, but without a ranking system there's very
        // little motivation to do that right now.
        if (m_hosted_game && m_hosted_game.game_in_progress)
        {
            auto game_result = m_hosted_game.report_scores(game_score.standings, players);
            auto result = m_room.report_game_result(game_result);
            if (result.success)
            {
                log_message("Successfully reported game scores from user ID %s: game ID %d", m_client.user_id, result.game_id);

                // If a recording was saved for the game, move it to the appropriate location
                if (!m_hosted_game_recording_file.empty)
                {
                    // TODO: Rename the recording based on the game ID we got from submitting the result
                    auto target_path = m_room.config().recordings_path ~ "public/";
                    if (!exists(target_path))
			            mkdirRecurse(target_path);

                    auto target_file = NativePath(target_path ~ m_hosted_game_recording_file.head.name);
                    moveFile(m_hosted_game_recording_file, target_file, true); // Allow copy+delete as fallback
                    log_message("Recording moved to %s", target_file);

                    m_hosted_game_recording_file = NativePath();
                }
            }
            else
            {
                log_message("Failed to report game scores from user ID %s!", m_client.user_id);
            }
        }
    }


    // Recording-related packets
    //---------------------------------------------------------------------------------------------

    private void handle_recording_stream_header(MythSocket socket)
    {
        if (!m_hosted_game_recording)
        {
            if (m_hosted_game)
            {
                // First recording packet - start a new stream
                m_hosted_game_recording = new GameRecording();
                log_message("Starting recording stream for user %s", m_client.user_id);
            }
            else
            {
                // NOTE: Could just log and ignore it instead, but let's be rude to tease out any bugs
                throw new ClientProtocolException("Received recording stream header packet, but user ID "
                                                  ~ to!string(m_client.user_id) ~ " is not hosting a game");
            }
        }

        assert(m_hosted_game_recording);
        m_hosted_game_recording.append_recording_header(socket.receive_packet_payload());
    }

    private void handle_recording_stream_command(MythSocket socket)
    {
        if (!m_hosted_game_recording || !m_hosted_game)
        {
            throw new ClientProtocolException("Received recording stream header packet, but user ID "
                                              ~ to!string(m_client.user_id) ~ " is not hosting a recorded game");
        }
        m_hosted_game_recording.append_recording_command(socket.receive_packet_payload());
    }

    private void handle_recording_stream_end(MythSocket socket)
    {
        if (!m_hosted_game_recording || !m_hosted_game)
        {
            throw new ClientProtocolException("Received recording stream end packet, but user ID "
                                              ~ to!string(m_client.user_id) ~ " is not hosting a recorded game");
        }

        int end_game_time;
        socket.receive_packet(packet_type._recording_stream_end_packet, end_game_time);

        // Either way we can close the recording stream after this function completes
        scope(exit) m_hosted_game_recording = null;

        auto config = m_room.config();
        m_hosted_game_recording_file =
            m_hosted_game_recording.end_recording(end_game_time, m_client.user_id,
                                                  config.recordings_path,
                                                  config.recordings_prefix,
                                                  config.recordings_ext);

        // If successful, report the file name of the recording to the game result
        m_hosted_game.set_recording_file_name(m_hosted_game_recording_file.head.name);
    }


    // Player-related packets
    //---------------------------------------------------------------------------------------------

    private void handle_player_mode(MythSocket socket)
    {
        auto new_mode = socket.receive_packet_typed!short(packet_type._set_player_mode_packet);
        if (new_mode < 0 || new_mode > player_mode.NUMBER_OF_PLAYER_MODES)
            throw new ClientProtocolException("Invalid player mode");

        m_client_deaf = (new_mode == player_mode.deaf);
    }

    private void handle_player_data(MythSocket socket)
    {
        metaserver_player_data player_data;
        string nick_name;
        string team_name;
        socket.receive_packet(packet_type._set_player_data_packet, player_data, nick_name, team_name);
        
        // We ignore most of the player data to avoid spoofing and other protocol abuse.
        // Exception is player "state" (in-game, etc) as that is what "dims" players
        m_client.set_player_state(player_data.state);
        m_room.send_client_update(m_client);
    }

    private void handle_player_info_query(MythSocket socket)
    {
        uint user_id = socket.receive_packet_typed!uint(packet_type._player_info_query_packet);

        // Look up client in room
        auto client_connection = m_room.find_client_in_room(user_id);
        if (!client_connection.isNull())
        {
            auto client = client_connection.client;
            player_info_packet info;

            string login = to!string(client.user_id);
            string order_name = "";

            info.primary_color = client.primary_color;
            info.secondary_color = client.secondary_color;
            info.icon_index = client.coat_of_arms_bitmap_index;
            info.administrator_flag = false;
            info.bungie_employee_flag = false;

            // Defaults are set up to work ok here
            auto server_info = m_login_server.data_store.get_player_info(client.user_id);

            if (client.guest)
                login = "Guest";

            // Fill in stats data
            {
                // For "Total" stats myth uses info.ranked_score_datum and info.overall_rank_data.ranked_game_data
                // For per-scoring stats myth uses info.ranked_score_datum_by_game_type[] and info.overall_rank_data.ranked_game_data_by_game_type[]

                info.ranked_score_datum.games_played      = cast(short)server_info.stats_total.games;
                info.ranked_score_datum.numerical_ranking = cast(short)server_info.stats_total.rank;
                info.overall_rank_data.total_users        = server_info.stats_total.total_player_count;

                // String into null terminated - must manually convert to mac roman since it's not a "string", but a char array
                {
                    ubyte[] encoded_player = string_to_mac_roman(server_info.stats_total.top_player_user_name);
                    size_t length = min(encoded_player.length, info.overall_rank_data.ranked_game_data.top_ranked_player.sizeof - 1);
                    info.overall_rank_data.ranked_game_data.top_ranked_player[0..length] = encoded_player[0..length];
                    info.overall_rank_data.ranked_game_data.top_ranked_player[length] = 0; // Null terminate
                }

                // TODO: Can clean this up with CTFE or similar
                // NOTE: These two fields being "short"s could be a problem in the long run :S
                info.ranked_score_datum.points                                   = cast(short)server_info.stats_total.points.val;
                info.overall_rank_data.ranked_game_data.points.best              = server_info.stats_total.points.max;
                info.overall_rank_data.ranked_game_data.points.average           = server_info.stats_total.points.avg;

                info.ranked_score_datum.wins                                     = cast(short)server_info.stats_total.wins.val;
                info.overall_rank_data.ranked_game_data.wins.best                = server_info.stats_total.wins.max;
                info.overall_rank_data.ranked_game_data.wins.average             = server_info.stats_total.wins.avg;

                info.ranked_score_datum.damage_inflicted                         = server_info.stats_total.damage_given.val;
                info.overall_rank_data.ranked_game_data.damage_inflicted.best    = server_info.stats_total.damage_given.max;
                info.overall_rank_data.ranked_game_data.damage_inflicted.average = server_info.stats_total.damage_given.avg;

                info.ranked_score_datum.damage_received                          = server_info.stats_total.damage_taken.val;
                info.overall_rank_data.ranked_game_data.damage_received.best     = server_info.stats_total.damage_taken.max;
                info.overall_rank_data.ranked_game_data.damage_received.average  = server_info.stats_total.damage_taken.avg;

                // TODO: Then the same as an array for each game type, etc.
            }

            send_packet(packet_type._player_info_packet,
                        info, login, client.player_data.nick_name, order_name,
                        server_info.city, server_info.state, server_info.country, server_info.quote);
        }
        else
        {
            // Should we still send a blank response?
        }
    }

    private void handle_update_player_info(MythSocket socket)
    {
        string city, state, country, quote;
        socket.receive_packet(packet_type._update_player_information_packet,
                              city, state, country, quote);

        // We ignore guest player info update attempts...
        if (!m_client.guest)
            m_login_server.data_store.set_player_info(m_client.user_id, city, state, country, quote);
    }

    @property public pure nothrow uint remote_address_ipv4() const { return m_remote_address_ipv4; }
    @property public pure nothrow const(Game) visible_hosted_game() const { return m_hosted_game; }
    @property public pure nothrow inout(RoomClient) client() inout { return m_client; }

    private LoginServer m_login_server;
    private Room m_room;
    private RoomClient m_client;
    private uint m_remote_address_ipv4; // Convenient to cache here
    private Game m_hosted_game = null;
    private GameRecording m_hosted_game_recording = null;
    private NativePath m_hosted_game_recording_file;

    private bool m_client_deaf;

    // A task responsible for sending data to this client
    // This allows us to control outgoing queue sizes and avoid ever blocking sender fibers
    private Task m_main_task;
    private Task m_send_task;

    private Exception m_pending_exception;
};
