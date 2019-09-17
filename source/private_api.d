module private_api;

import std.stdint;

//-------------------------------------------------------------------------------------------------

// NOTE: This token does not appear to get byte swapped at all in the original
// metaserver, so we declare it as a byte array to be similar. It probably doesn't
// matter though as long as we are consistent on send/receive, since I don't think
// the client does anything with it other than copy it when it sends data back.
immutable MAXIMUM_HANDOFF_TOKEN_SIZE = 32;
public alias ubyte[MAXIMUM_HANDOFF_TOKEN_SIZE] authentication_token_type;

//-------------------------------------------------------------------------------------------------
struct rgb_color // Myth client structure, hence different style naming
{
    ushort red;
    ushort green;
    ushort blue;
    ushort flags;
}

// NOTE: Myth RGB colors are 16 bit fixed point values
// Thus 24-bit int conversions are lossy (we lose 8 LSBs). However these bits are
// not used in standard 24-bit color modes, so it's not clear why Myth has them to start with...
public int rgb_color_to_int(in rgb_color c)
{
    return 
        ((cast(int)c.red   << 8) & 0xFF0000) |
        ((cast(int)c.green     ) & 0x00FF00) |
        ((cast(int)c.blue  >> 8) & 0x0000FF);
}

public rgb_color int_to_rgb_color(int h)
{
    rgb_color c = {
        cast(ushort)((h & 0xFF0000) >> 8),
        cast(ushort)((h & 0x00FF00)     ),
        cast(ushort)((h & 0x0000FF) << 8)
    };
    return c;
}

// Immutable data about a given player
// Does *not* include state and other mutable data that is captured in the "Client" class
// Data in this class should be considered to be *public information*
struct PlayerData
{
    int user_id;
    bool guest;
    
    string nick_name;
    string team_name;
    int primary_color;
    int secondary_color;
    int coat_of_arms_bitmap_index;
    int order_id;

    int game_version;
    int build_number;
    string ip_address;
};

// Class because we want to inherit from it in various places, but public, mutable fields
// because it needs to be able to be serialized and so on. Imperfect but good enough for this application.
class Client
{
    public PlayerData m_player_data;	
    public authentication_token_type m_authentication_token;

    // Convenience
    public @property const(authentication_token_type) authentication_token() const { return m_authentication_token; }
    public @property ref const(PlayerData) player_data() const { return m_player_data; }
    public @property bool guest() const { return player_data.guest; }
    public @property int user_id() const { return player_data.user_id; }

    // 428+ adds support for host proxies and fixes some related bugs
    public @property bool supports_host_proxies() const { return player_data.build_number >= 428; }
}

//-------------------------------------------------------------------------------------------------
// NOTE: We make this a class to get reference semantics, since it already includes some internals
// such as dynamic arrays that have reference semantics.
public class GameResult
{
    public struct Player
    {
        PlayerData data;

        bool host;
        bool captain;
        bool dropped;

        int units_killed;
        int units_lost;
        int damage_given;
        int damage_taken;
    };
    public struct Team
    {
        int place; // 1st, 2nd, 3rd, etc. This is 1-based, not 0-based
        bool place_tie; // Is there another team with the same place?
        bool spectators;
        bool eliminated;

        // Convenience... other than spectators, this will always be the same as the captains team name
        string team_name;

        // NOTE: We could work out aggregate team stats here too...
        // Arguably that's just as easy for the web server/database to do though

        Player[] players;
    };

    int room_type; // 0 = Unranked, 1 = Ranked, 2 = Tournament
    int team_count; // Exclused spectator team if present
    int player_count;

    string game_name;
    string map_name;
    int scoring;
    int difficulty; // 0 = Timid, 1 = Simple, ...
    int time_limit;
    int planning_time_limit;

    bool cooperative;
    bool allow_teams;
    bool allow_unit_trading;
    bool allow_veterans;
    bool allow_alliances;
    bool overhead_map;
    bool deathmatch;
    bool vtfl;
    bool anti_clump;

    string start_datetime;
    string end_datetime;

    int ended_code; // 0 = normal, 1 = server quit, 2 = player quit		
    int duration;
    string recording_file_name; // pathless, '' if no recording was saved

    Team[] teams;
};

public struct GameResultReturn
{
    bool success;
    int game_id;
};

public struct QueryPlayerInfoReturn
{
    string city;
    string state;
    string country;
    string quote;

    public struct StatDistributionValue
    {
        int val;
        int max;
        int avg;
    }

    public struct CategoryStats
    {
        int games;
        int rank;
        int total_player_count;
        string top_player_user_name;
        StatDistributionValue points;
        StatDistributionValue wins;
        StatDistributionValue damage_given;
        StatDistributionValue damage_taken;
    }

    CategoryStats stats_total;
    CategoryStats[] stats_per_type;
};

enum RoomType : short
{
    unranked = 0,
    ranked,
    tournament,
    num
};

public class PublicRoomStatus
{
    int id; // Unique per room
    string name;
    int type; // 0 = unranked, 1 = ranked, 2 = tournament

    public struct Player
    {
        bool guest;
        int user_id; // Only interesting/valid if guest is false
        string nick_name;
        int primary_color;
        int secondary_color;
        bool in_game;
    };
    Player[] players;

    public struct Game
    {
        string name;
        string map_name;
        string scoring_name;

        // NOTE: Caller can match this with someone in the player list
        // if they want nick name and other info. Works even with guest IDs
        // since the status query is atomically returned.
        int host_user_id;

        int players;
        int max_players;

        int elapsed_seconds; // 0 = game not currently in progress
    };
    Game[] games;
};

public class PublicServerStatus
{
    PublicRoomStatus[] rooms;
};

