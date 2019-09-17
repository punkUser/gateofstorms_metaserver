module room_client;

import endian;
import exceptions;
import myth_socket;
import mac_roman;
import private_api;

import std.string;
import std.conv;
import std.bitmanip;
import std.algorithm;
import std.stdio;
import std.array;
import std.format;
import std.datetime;
import std.exception;

enum
{
    MAXIMUM_LOGIN_LENGTH = 15,
    MAXIMUM_PASSWORD_LENGTH = 15,
    MAXIMUM_PLAYER_NAME_LENGTH = 31,
    MAXIMUM_DESCRIPTION_LENGTH = 431,
    MAXIMUM_NUMBER_OF_GAME_TYPES = 16,
    MAXIMUM_BUDDIES = 16,	// Build 101CL - PAB - Expand buddy list
    MAXIMUM_ORDER_MEMBERS = 50,
    MAXIMUM_ORDER_NAME_LENGTH= 63 // Build 343 - ALS - was 31
};

struct metaserver_player_aux_data
{
    ushort verb;
    ushort flags;
    int ranking;
    uint player_id; // This time it's a uint, whereas most of the time it's int...
    int room_id;
    short caste;
    short player_data_length;
    short order;
    short pad;
};

enum player_state
{
    idle = 0,
    in_game,
    NUMBER_OF_PLAYER_STATES
};

struct bungie_net_player_score_datum
{
    short games_played;
    short wins, losses, ties;
    int damage_inflicted, damage_received;

    short disconnects;
    ushort pad;

    short points;
    short rank;

    short highest_points;
    short highest_rank;

    uint numerical_ranking;

    ubyte[16] unused;
};
static assert(bungie_net_player_score_datum.sizeof == 48);

struct ranking_data
{
    uint average;
    uint best;
};

struct game_rank_data
{
    ubyte[MAXIMUM_PLAYER_NAME_LENGTH+1] top_ranked_player;
    ranking_data points;
    ranking_data games_played;
    ranking_data wins;
    ranking_data damage_inflicted;
    ranking_data damage_received;
};

struct overall_ranking_data
{
    uint total_users;
    uint total_orders;
    game_rank_data unranked_game_data;
    game_rank_data ranked_game_data;
    game_rank_data[MAXIMUM_NUMBER_OF_GAME_TYPES] ranked_game_data_by_game_type;
    game_rank_data order_unranked_game_data;
    game_rank_data order_ranked_game_data;
    game_rank_data[MAXIMUM_NUMBER_OF_GAME_TYPES] order_ranked_game_data_by_game_type;
};

struct metaserver_player_data
{
    byte coat_of_arms_bitmap_index;
    byte caste_bitmap_index;
    short state;
    rgb_color primary_color;
    rgb_color secondary_color;

    short order_index;
    short game_version; // game version - ex: Myth II 1.5.0 -> 2150, multiplied by 10 for demo version (ie 21500)
    short build_number;
    short[6] unused; // NOTE: This will still get endian swapped...
};
static assert(metaserver_player_data.sizeof <= MAXIMUM_METASERVER_PLAYER_DATA_SIZE);

struct player_info_packet
{
    int administrator_flag; // boolean
    int bungie_employee_flag; // boolean
    short order_index;
    short icon_index;
    rgb_color primary_color;
    rgb_color secondary_color;
    bungie_net_player_score_datum unranked_score_datum;
    bungie_net_player_score_datum ranked_score_datum;
    bungie_net_player_score_datum[MAXIMUM_NUMBER_OF_GAME_TYPES] ranked_score_datum_by_game_type;
    bungie_net_player_score_datum order_unranked_score_datum;
    bungie_net_player_score_datum order_ranked_score_datum;
    bungie_net_player_score_datum[MAXIMUM_NUMBER_OF_GAME_TYPES] order_ranked_score_datum_by_game_type;
    overall_ranking_data overall_rank_data;
    // char * login
    // char * name
    // char * order_name
    // char * description
};
static assert(player_info_packet.sizeof == 4356);


public enum ClientHostProxyState {
    on,
    off,
    unknown
}


// NOTE: This structure is mainly for use by the rooms/room connections
// It has private/immutable data and therefor cannot be directly serialized over the private API
class RoomClient : Client
{
    public this(const(Client) info)
    {
        m_player_data = info.m_player_data;
        m_authentication_token = info.m_authentication_token;

        // Setup metaserver player data structure
        m_metaserver_player_data.coat_of_arms_bitmap_index = cast(byte)info.player_data.coat_of_arms_bitmap_index;
        m_metaserver_player_data.primary_color   = int_to_rgb_color(info.player_data.primary_color);
        m_metaserver_player_data.secondary_color = int_to_rgb_color(info.player_data.secondary_color);

        m_metaserver_player_data.game_version = cast(short)info.player_data.game_version;
        m_metaserver_player_data.build_number = cast(short)info.player_data.build_number;
        
        // This one seems unused by Myth. Instead it uses the one in the aux_player_data structure.
        m_metaserver_player_data.caste_bitmap_index = 0;
        m_metaserver_player_data.order_index = cast(short)info.player_data.order_id;

        m_metaserver_player_data.state = player_state.idle;

        // These get updated async by the room server
        m_caste_bitmap_indices[] = -1; // No icon
    }

    // Flag player as ingame or not
    public nothrow void set_player_state(short state)
    {
        m_metaserver_player_data.state = state;
    }
    @property public nothrow bool in_game() const { return m_metaserver_player_data.state == player_state.in_game; }
    
    // Return a big endian stream built from the player data
    public immutable(ubyte)[] player_data_big_endian() const
    {
        // NOTE: This function also duplicates a bit of functionality found in the packet
        // encoding logic, but it's convenient so we'll leave it for now.

        // Swap endian if necessary and return a copy
        union player_data_union
        {
            ubyte[metaserver_player_data.sizeof] bytes = void;
            metaserver_player_data data;
        }

        player_data_union player_data_big_endian = void;
        player_data_big_endian.data = native_to_big_endian(m_metaserver_player_data);
        ubyte[] result_bytes = player_data_big_endian.bytes;
        result_bytes ~= string_to_mac_roman(m_player_data.nick_name);
        result_bytes ~= string_to_mac_roman(m_player_data.team_name);

        return assumeUnique(result_bytes);
    }

    public pure nothrow int caste_bitmap_index(RoomType type) const { return m_caste_bitmap_indices[type]; }
    public nothrow void set_caste_bitmap_index(RoomType type, int caste) { m_caste_bitmap_indices[type] = caste; }
    public nothrow void set_caste_bitmap_indices(int[RoomType.num] caste) { m_caste_bitmap_indices = caste; }

    public pure nothrow ClientHostProxyState host_proxy_state() const { return m_host_proxy_state; }
    public nothrow void set_host_proxy_state(ClientHostProxyState state) { m_host_proxy_state = state; }

    // Convenience
    @property public pure rgb_color primary_color() const { return m_metaserver_player_data.primary_color; }
    @property public pure rgb_color secondary_color() const { return m_metaserver_player_data.secondary_color; }
    @property public pure byte coat_of_arms_bitmap_index() const { return m_metaserver_player_data.coat_of_arms_bitmap_index; }
    @property public pure short order_id() const { return m_metaserver_player_data.order_index; }
    @property public pure short build_number() const { return m_metaserver_player_data.build_number; }

    // Client info (mostly immutable, few minor exceptions like player state)
    private metaserver_player_data m_metaserver_player_data;

    // Mutable data
    private int[RoomType.num] m_caste_bitmap_indices;
    private ClientHostProxyState m_host_proxy_state = ClientHostProxyState.unknown;
};
