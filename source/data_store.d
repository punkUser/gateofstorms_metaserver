module data_store;

import log;
import private_api;
import exceptions;

import std.stdio;
import std.uri;
import std.conv;
import std.array;
import std.file;
import std.path;
import std.variant;
import std.algorithm;
import std.range;
import std.digest.md;
import std.stdint;
import std.typecons;

import vibe.vibe;
import mysql;

// NOTE: We use explicit params here instead of a PlayerData structure
// because some of the fields can't legitimately be returned/modified by the HTTP API.
public struct UserLoginParams
{
    bool update_player_data;
    string nick_name;
    string team_name;
    int primary_color;  
    int secondary_color;
    int coat_of_arms_bitmap_index;
};

public struct UserLoginReturn
{
    bool success = false;

    int user_id; // Unused when guest is true
    bool guest = false;
    
    // These override what the user sent
    string nick_name;
    string team_name;
    int primary_color;
    int secondary_color;
    int coat_of_arms_bitmap_index;

    // Error info
    bool banned = false;
    string banned_reason;
};

interface DataStoreInterface
{
    UserLoginReturn user_login_token(UserLoginParams params, string user_name, string password);
    bool set_player_info(int user_id, string city, string state, string country, string quote);
    GameResultReturn add_game_result(GameResult game);
    QueryPlayerInfoReturn get_player_info(int id);
    string get_join_room_message(bool guest);
    int get_user_admin_level(int user_id);
    bool ban_user(int user_id, int days, string reason);
}

//-------------------------------------------------------------------------------------------------
class DataStoreNull : DataStoreInterface
{
    UserLoginReturn user_login_token(UserLoginParams params, string user_name, string password)
    {
        UserLoginReturn result;
        result.success                   = true;
        result.guest                     = true;
        result.user_id                   = -1; // Caller will assign a user ID
        result.nick_name                 = params.nick_name;
        result.team_name                 = params.team_name;
        result.primary_color             = params.primary_color;
        result.secondary_color           = params.secondary_color;
        result.coat_of_arms_bitmap_index = params.coat_of_arms_bitmap_index;
        return result;
    }

    GameResultReturn add_game_result(GameResult game)
    {
        GameResultReturn result;
        result.success = false;
        result.game_id = -1;
        return result; // noop
    }

    bool ban_user(int user_id, int days, string reason)
    {
        return false; // noop
    }

    bool set_player_info(int user_id, string city, string state, string country, string quote)
    {
        return false; // noop
    }

    QueryPlayerInfoReturn get_player_info(int id)
    {
        QueryPlayerInfoReturn result;
        return result;
    }

    string get_join_room_message(bool guest)
    {
        return "Metaserver is running in test mode; some functions will be unavailable.";
    }

    int get_user_admin_level(int user_id)
    {
        return false;
    }
}


//-------------------------------------------------------------------------------------------------
class DataStoreMysql : DataStoreInterface
{
    public this(string database_connection_string)
    {
        m_db = new MySQLClient(database_connection_string);
    }

    // Internal function to implement the user login after authentication is established
    // Retrieves/updates player data, etc.
    private UserLoginReturn RegisteredUserLogin(UserLoginParams params, int user_id)
    {
        auto db = m_db.lockConnection();

        UserLoginReturn result;
        result.success                      = false;
        result.user_id                      = user_id;
        result.nick_name                    = params.nick_name;
        result.team_name                    = params.team_name;
        result.primary_color                = params.primary_color;
        result.secondary_color              = params.secondary_color;
        result.coat_of_arms_bitmap_index    = params.coat_of_arms_bitmap_index;
        result.banned                       = false;

        db.execute(
                "SELECT
                    nick_name, team_name, primary_color, secondary_color, coat_of_arms_bitmap_index,
                    IF(banned_until IS NULL OR (NOW() - banned_until > 0), 0, 1) as banned,
                    banned_reason,
                    last_login_datetime
                FROM metaserver_users
                WHERE id = ?;", user_id, (MySQLRow row) {

            // General user data
            result.success              = true;
            result.user_id              = user_id;

            if (!params.update_player_data)
            {
                // Use saved player data
                result.nick_name                    = row.nick_name.get!string;
                result.team_name                    = row.team_name.get!string;
                result.primary_color                = row.primary_color.get!int;
                result.secondary_color              = row.secondary_color.get!int;
                result.coat_of_arms_bitmap_index    = row.coat_of_arms_bitmap_index.get!int;
            }

            // Check if the user is banned from the metaserver
            if (row.banned.peek!long != 0)
            {
                result.success = false;
                result.banned = true;
                result.banned_reason = row.banned_reason.get!string;
            }

            // If this is their first login, always update their user data
            if (row.last_login_datetime.isNull)
                params.update_player_data = true;
        });

        // The row should be there... this is meant to be an already authenticated user
        if (!result.success && !result.banned)
            throw new InternalException("RegisteredUserLogin couldn't find user ID " ~ to!string(user_id) ~ "!");

        if (params.update_player_data)
        {
            // Use the data they provided and update it in the database
            db.execute(
                    "UPDATE metaserver_users
                    SET nick_name = ?, team_name = ?, primary_color = ?, secondary_color = ?,
                        coat_of_arms_bitmap_index = ?, last_login_datetime = CURRENT_TIMESTAMP
                    WHERE id = ?;",
                params.nick_name, params.team_name, params.primary_color, params.secondary_color,
                params.coat_of_arms_bitmap_index, user_id);

            // Rows affected might be zero if none of the actual data changed, even if the update path was triggered.
            // Since this isn't a critical error in any case, we ignore the result other than logging.
            if (db.affected() > 0)
                log_message("DataStore: Updated player data for user ID %s.", user_id);
        }
        else
        {
            // Otherwise use their stored data; only update last_login_datetime
            db.execute(
                    "UPDATE metaserver_users
                    SET last_login_datetime = CURRENT_TIMESTAMP
                    WHERE id = ?;",
                user_id);
        }

        return result;
    }

    UserLoginReturn user_login_token(UserLoginParams params, string user_name, string password)
    {
        UserLoginReturn result;
        result.success                   = false;
        result.guest                     = true;
        result.user_id                   = -1; // Caller will assign a user ID
        result.nick_name                 = params.nick_name;
        result.team_name                 = params.team_name;
        result.primary_color             = params.primary_color;
        result.secondary_color           = params.secondary_color;
        result.coat_of_arms_bitmap_index = params.coat_of_arms_bitmap_index;

        auto db = m_db.lockConnection();

        // Query for any user data that we have for the given user name
        db.execute(
                "SELECT user_id, password_token
                FROM metaserver_login_tokens
                WHERE user_name_token = ?;", user_name, (MySQLRow row) {
            
            int user_id = row.user_id.get!int;
            string db_password_token = row.password_token.get!string;

            // Compare password
            // We still do this here rather than putting it in the SQL to differentiate between possibly
            // mistyped passwords and legitimate guest login attempts. Nothing technical prevents us
            // now from just always falling back on guest login, but it may be a confusing user experience.
            if (db_password_token == password)
                result = RegisteredUserLogin(params, user_id);
        });

        if (result.success)
        {
            // Nothing more to do
        }
        else if (password.empty)
        {
            // No user with this user name token: allow guest login
            result.success = true;
            result.guest = true;
        }
        else
        {
            // Otherwise we fail
            result.success = false;
        }

        return result;
    }

    GameResultReturn add_game_result(GameResult game)
    {
        GameResultReturn result;
        result.success = false;
        result.game_id = -1;

        // Insert game into database
        // NOTE: We could do some sort of fancy compile-time reflection/JSON->database logic as
        // we used to have in PHP, but without the extra glue layer now I don't think it's worth
        // the complexity vs. just spelling it out here.
        auto db = m_db.lockConnection();

        auto games_inserter = inserter(db, "metaserver_games",
            "room_type", "team_count", "player_count", "game_name", "map_name", "scoring", "difficulty", "time_limit", "planning_time_limit",
            "cooperative", "allow_teams", "allow_unit_trading", "allow_veterans", "allow_alliances", "overhead_map", "deathmatch", "vtfl", "anti_clump",
            "start_datetime", "end_datetime", "ended_code", "duration", "recording_file_name");

        games_inserter.row(
            game.room_type, game.team_count, game.player_count, game.game_name, game.map_name, game.scoring, game.difficulty, game.time_limit, game.planning_time_limit,
            game.cooperative, game.allow_teams, game.allow_unit_trading, game.allow_veterans, game.allow_alliances, game.overhead_map, game.deathmatch, game.vtfl, game.anti_clump,
            game.start_datetime, game.end_datetime, game.ended_code, game.duration, game.recording_file_name);
        games_inserter.flush();
        if (db.affected() < 1)
        {
            log_message("DataStore: Error inserting game into database!");
            return result;
        }

        int game_id = cast(int)(db.insertID);
        result.game_id = game_id;

        // Insert teams and players

        // TODO: Could probably clean some of this up with structure inserters now
        auto teams_inserter = inserter(db, "metaserver_games_teams", "metaserver_games_id", "place", "place_tie", "spectators", "eliminated", "team_name");

        auto player_inserter = inserter(db,
            "metaserver_games_teams_players", "metaserver_games_teams_id", "user_id", "nick_name", "team_name",
            "primary_color", "secondary_color", "coat_of_arms_bitmap_index",
            "game_version", "build_number", "ip_address",
            "host", "captain", "dropped",
            "units_killed", "units_lost", "damage_given", "damage_taken");

        foreach (team; game.teams)
        {
            teams_inserter.row(game_id, team.place, team.place_tie, team.spectators, team.eliminated, team.team_name);
            teams_inserter.flush();
            if (db.affected() < 1)
            {
                log_message("DataStore: Error inserting team into database for game ID %s!", result.game_id);
                return result;
            }
            int team_id = cast(int)(db.insertID);

            foreach (player; team.players)
            {
                // Guest players should get null for their user_id
                if (player.data.guest)
                {
                    player_inserter.row(
                        team_id, null, player.data.nick_name, player.data.team_name,
                        player.data.primary_color, player.data.secondary_color, player.data.coat_of_arms_bitmap_index,
                        player.data.game_version, player.data.build_number, player.data.ip_address,
                        player.host, player.captain, player.dropped,
                        player.units_killed, player.units_lost, player.damage_given, player.damage_taken);
                }
                else
                {
                    player_inserter.row(
                        team_id, player.data.user_id, player.data.nick_name, player.data.team_name,
                        player.data.primary_color, player.data.secondary_color, player.data.coat_of_arms_bitmap_index,
                        player.data.game_version, player.data.build_number, player.data.ip_address,
                        player.host, player.captain, player.dropped,
                        player.units_killed, player.units_lost, player.damage_given, player.damage_taken);
                }

                player_inserter.flush();        // Maybe defer this one
                if (db.affected() < 1)
                {
                    log_message("DataStore: Error inserting player into database for game ID %s!", result.game_id);
                    return result;
                }
            }
        }

        result.success = true;
        return result;
    }

    bool ban_user(int user_id, int days, string reason)
    {
        auto db = m_db.lockConnection();
        db.execute(
                "UPDATE metaserver_users
                SET
                    banned_until = NOW() + INTERVAL ? DAY,
                    banned_reason = ?
                WHERE id = ?;",
            days, reason, user_id);
        return (db.affected() > 0);
    }

    bool set_player_info(int user_id, string city, string state, string country, string quote)
    {
        auto db = m_db.lockConnection();
        db.execute(
                "UPDATE metaserver_users
                SET city = ?, state = ?, country = ?, quote = ?
                WHERE id = ?;",
            city, state, country, quote, user_id);
        return (db.affected() > 0);
    }

    QueryPlayerInfoReturn get_player_info(int user_id)
    {
        auto db = m_db.lockConnection();
        QueryPlayerInfoReturn result;
        db.execute("SELECT city, state, country, quote FROM metaserver_users WHERE id = ?;", user_id, (MySQLRow row) {
            result.city    = row.city.get!string;
            result.state   = row.state.get!string;
            result.country = row.country.get!string;
            result.quote   = row.quote.get!string;
        });
        return result;
    }

    string get_join_room_message(bool guest)
    {
        auto db = m_db.lockConnection();

        int guest_flag = guest ? 100 : 1;

        string message = "";
        db.execute(
                "SELECT message FROM metaserver_join_room_messages
                WHERE guest_only < ?
                ORDER BY priority ASC;", guest_flag, (MySQLRow row) {
            if (!row.message.isNull)
                message ~= row.message.get!string ~ "\n";
        });

        return message;
    }

    int get_user_admin_level(int user_id)
    {
        auto db = m_db.lockConnection();

        int admin_level = 0;
        db.execute("SELECT admin_level FROM metaserver_users WHERE id = ?;", user_id, (MySQLRow row) {
            admin_level = row.admin_level.get!int;
        });

        return admin_level;
    }

    // NOTE: Be a bit careful with state here. These functions can be re-entrant due to
    // triggering blocking calls and then having other requests submitted by separate fibers.
    // This it's safest to keep all of this state immutable.

    // This is internally a connection pool, so safe to use here
    private MySQLClient m_db;
};