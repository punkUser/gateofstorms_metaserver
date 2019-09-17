module metaserver_config;

import private_api;

import vibe.vibe;

public struct MetaserverConfig
{
    @optional string server_address = "127.0.0.1";    // NOTE: Should be set properly for any public server
    @optional string database_connection_string = ""; // Empty = test mode!

    @optional int http_server_port = 8080;
    @optional string http_server_log_file = "";

    @optional bool allow_guests = true;               // Guests log in with empty passwords
    @optional bool nick_name_is_user_name = false;    // If true, forces nick names to be the same as user names (where possible)

    @optional int login_port = 6321;

    // NOTE: For full functionality, requires 428+ due to host proxy support and related fixes
    @optional int minimum_client_build = 427;

    struct RoomConfig
    {
        @optional int room_id = -1;    // Controls which banner is used; -1 = last room ID +1
        @optional string name = "";    // Mainly for log file; "" = some default name based on ID
        @optional RoomType type = RoomType.unranked;
        @optional bool requires_films = false;
    };

    // Rooms
    @optional RoomConfig[] rooms = [
        {-1, "", RoomType.unranked, false},
        {-1, "", RoomType.unranked, true},
        {-1, "", RoomType.ranked, true},
        {-1, "", RoomType.ranked, true},
        {-1, "", RoomType.tournament, true},
        {-1, "", RoomType.tournament, true},
    ];

    @optional int room_start_port = 6323; // NOTE: Could let the user customize this per room...
    @optional int maximum_users_per_room = 999;

    @optional string recordings_path = "recordings/";
    @optional string recordings_prefix = "";
    @optional string recordings_ext = ".m2rec";

    // Host proxy
    @optional int host_proxy_pool_start = 61000;
    @optional int host_proxy_pool_count = 10;
};
