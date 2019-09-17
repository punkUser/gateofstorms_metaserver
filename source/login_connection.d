module login_connection;

import room_client;
import exceptions;
import login_server;
import myth_socket;
import connection;
import mac_roman;
import private_api;

import std.socket;
import std.conv;
import std.stdio;
import std.string;
import std.algorithm;
import vibe.core.net;

private enum playform_type
{
    macintosh_classic = 100,
    macintosh_modern = 101,
    windows_classic = 200,
    windows_modern = 201,
    linux = 300
};

private enum
{
    _change_player_data_on_login_flag = 1 // This is really the only relevant one for us
};

private struct login_data
{
    short metaserver_version; // Seems unused currently
    short platform_type;
    int flags;
    int user_id;
    short max_authentication;
    short player_data_size;
    ubyte[MAXIMUM_METASERVER_APPLICATION_NAME+1] application; // "MYTH2" for us
    ubyte[MAXIMUM_METASERVER_BUILD_DATE+1] build_date;
    ubyte[MAXIMUM_METASERVER_BUILD_TIME+1] build_time;
    ubyte[MAXIMUM_METASERVER_USERNAME+1] username;
    ubyte[MAXIMUM_METASERVER_PLAYER_DATA_SIZE] player_data;
    short country_code;
    short padding;
};

private struct version_control_packet
{
    int platform_type; // operating system
    int application_version;
    int patch_number;
    int build_number;
};

private struct successful_login_packet
{
    int user_id;
    short order;
    short order_2; // ?? Not sure why this is sent twice but it is...
    authentication_token_type authentication_token;
};

private enum authentication_types
{
    plaintext_encryption,
    braindead_simple_encryption,
    md5_encryption,
    NUMBER_OF_ENCRYPTION_TYPES
};

private struct password_challenge_packet
{
    short authentication_type;
    ubyte[16] salt;
};


public final class LoginConnection : Connection
{
    public this(LoginServer server)
    {
        super();
        m_server = server;
    }

    protected override void run_internal(MythSocket socket)
    {
        socket.negotiate_session_key();

        auto login = socket.receive_packet_typed!login_data(packet_type._login_packet);
        string user_name = mac_roman_to_string(login.username);

        // Reject non-Myth 2 clients
        if (!equal(login.application[0..5], "MYTH2"))
            throw new InvalidGameException(user_name);

        // Send password challenge
        // NOTE: We always do this (even for guests) to simplify the protocol
        // NOTE: We require a session key (see negotiate session key), so this will end up encrypted, even
        // though we call it "plain text".
        password_challenge_packet password_challenge;
        password_challenge.authentication_type = authentication_types.plaintext_encryption;
        // Salt unused
        socket.send_packet(packet_type._password_challenge_packet, password_challenge);

        // Receive password (note: NOT null terminated)
        ubyte[] password_payload;
        socket.receive_packet(packet_type._password_response_packet, password_payload);
        string password = mac_roman_to_string(password_payload);

        // Request client version information
        socket.send_packet(packet_type._send_versions_packet);
        auto version_data = socket.receive_packet_typed!version_control_packet(packet_type._version_control_packet);

        // We don't support pre-1.8 clients for a variety of reasons
        // Also respect the minimum build in config
        if (version_data.application_version < 2180 ||
            version_data.build_number < m_server.config.minimum_client_build)
        {
            throw new InvalidVersionException(user_name, version_data.application_version, version_data.build_number);
        }

        metaserver_player_data player_data;
        string nick_name, team_name;
        MythSocket.decode_payload(login.player_data[0 .. login.player_data_size], player_data, nick_name, team_name);

        // Add client to our server list
        // NOTE: It's ok to add the client to the server before sending the successful login packet here
        // since we only send the various update packets to clients that are currently in rooms
        auto client = m_server.add_client(user_name, password, nick_name, team_name,
                                          player_data.primary_color, player_data.secondary_color, player_data.coat_of_arms_bitmap_index,
                                          player_data.game_version, player_data.build_number,
                                          socket.remote_address_string,
                                          (login.flags & _change_player_data_on_login_flag) != 0);

        successful_login_packet login_packet;
        login_packet.user_id = client.player_data.user_id;
        login_packet.order = cast(short)client.player_data.order_id;
        login_packet.order_2 = login_packet.order;
        login_packet.authentication_token = client.authentication_token;
        socket.send_packet(packet_type._user_successful_login_packet, login_packet);

        {
            // Sort of silly, but we need to construct a temp "Room Client" object just to get the player data payload
            auto temp_client = new RoomClient(client);
            auto player_data_payload = temp_client.player_data_big_endian();

            // NOTE: Nothing but the player data segment seems to be used here...
            metaserver_player_aux_data aux_data_packet;
            aux_data_packet.player_data_length = cast(short)player_data_payload.length;

            // Send back aux data, followed by player data
            socket.send_packet(packet_type._set_player_data_from_metaserver_packet, aux_data_packet, player_data_payload);
        }

        // Send room data (specialized for this client)
        socket.send_packet(packet_type._room_list_packet, m_server.get_room_list_for_client(client));

        // We could wait here for them to disconnect, but might as well return and close the connection ourselves...
    }

    private LoginServer m_server;
};
