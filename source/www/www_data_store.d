import std.typecons;
import std.conv;
import std.range;
import std.algorithm;
import std.digest.md;
import std.stdio;
import std.stdint;
import std.random;
import std.datetime;
import std.uni;
import std.format;

import vibe.vibe;
import mysql;

import log;

// A few handy helpers
string ratio_string(int num, int denom)
{
    return format("%.3f", cast(float)num / cast(float)max(denom, 1));
}


public struct Tournament
{
    int tournament_id;
	int organizer_user_id;		// -1 if no organizer
    string name;
    string short_name;
    string start_month_string;
}

public struct TournamentRoundList
{
    int round_id;
    long game_count;
    string name;
    string start_date_string;
}

public struct TournamentRound
{
    int tournament_id;
    int round_id;
    string name;
}

public struct GameList
{
    int game_id;
    int player_count;
    string start_date_string;
    string map_name;
    string scoring_name;
    string recording_file_name;
    string duration_string;
}

public struct User
{
	string nick_name;
	string last_login_date_string;
	string steam_profile_url;
}

public struct Game
{
    string map_name;
    string scoring_name;
    string difficulty_name;
    string time_limit_string;
    string planning_time_limit_string;
    string start_date;
    string duration_string;
    string recording_file_name;

    int time_limit;             // In "myth ticks" (30ths of a second) - see strings above for user visible formats
    int planning_time_limit;    // In "myth ticks" (30ths of a second) - see strings above for user visible formats

    bool cooperative;
    bool allow_teams;
    bool allow_unit_trading;
    bool allow_veterans;
    bool allow_alliances;
    bool overhead_map;
    bool deathmatch;
    bool vtfl;
    bool anti_clump;

    public struct Player
    {
        string nick_name;

        int user_id;            // Invalid if guest = true
        int units_killed;
        int units_lost;
        int damage_given;
        int damage_taken;

        bool guest;        
        bool host;
        bool captain;
        bool dropped;
        
        // More data available in the db, but not relevant for now

        string status_string(string team_status_string = "")
        {
            return dropped ? "Dropped" : team_status_string;
        }
        string damage_ratio_string()    { return ratio_string(damage_given, damage_taken);  }
        string units_ratio_string()     { return ratio_string(units_killed, units_lost);    }
    }

    public struct Team
    {
        int place;
        bool place_tie;
        bool spectators;
        bool eliminated;
        string team_name;

        // Accumulated from player data
        int units_killed = 0;
        int units_lost = 0;
        int damage_given = 0;
        int damage_taken = 0;

        Player[] players;

        string status_string()
        {
            return eliminated ? "Eliminated" : "";
        }
        string damage_ratio_string()    { return ratio_string(damage_given, damage_taken);  }
        string units_ratio_string()     { return ratio_string(units_killed, units_lost);    }
    }

    Team[] teams;


    // Handy utilities
    public Player find_host_player() const
    {
        // Efficiency, etc... meh
        foreach (ref team; teams)
        {
            foreach (ref player; team.players)
            {
                if (player.host)
                    return player;
            }
        }
        return Player();        // Should not get hit under normal circumstances...
    }

    public string[] get_settings_strings()
    {
        auto settings = new string[0];
        if (cooperative)
        {
            if (allow_veterans)             settings ~= "Veterans Allowed";
            if (allow_teams)                settings ~= "Teams Allowed";
            if (!overhead_map)              settings ~= "No Overhead Map";
        }
        else
        {
            if (allow_unit_trading)         settings ~= "Unit Trading Enabled";
            if (allow_veterans)             settings ~= "Veterans Allowed";
            if (allow_teams)                settings ~= "Teams Allowed";
            if (!allow_alliances)           settings ~= "No Alliances";
            if (!overhead_map)              settings ~= "No Overhead Map";
            if (deathmatch)                 settings ~= "Deathmatch";
                                            settings ~= time_limit_string ~ " Time Limit";
            if (planning_time_limit > 0)    settings ~= planning_time_limit_string ~ " Planning Time";
        }

        // TODO: vTFL/anti-clump?

        if (sicmp(difficulty_name, "Normal") != 0)
            settings ~= difficulty_name ~ " Difficulty Level";

        return settings;
    }
}

public struct PlayerStats
{
    int user_id;
    string nick_name;
    int units_killed;
    int units_lost;
    int damage_given;
    int damage_taken;
    int win_count;
    int loss_count;
    int tie_count;

    string damage_ratio_string()    { return ratio_string(damage_given, damage_taken);  }
    string units_ratio_string()     { return ratio_string(units_killed, units_lost);    }
}

// Used for column ordering/sorting in stats queries
public enum PlayerStatsColumn {
    Name = 0,
    WinTieLoss,
    UnitsKilled,
    UnitsLost,
    UnitsRatio,
    DamageGiven,
    DamageTaken,
    DamageRatio,
    Count
};
private struct PlayerStatsColumnOrdering
{
    string asc;
    string desc;
};
private immutable PlayerStatsColumnOrdering[PlayerStatsColumn.Count] k_player_stats_column_order = [
    { "nick_name ASC",                                 "nick_name DESC" },
    { "win_count ASC, tie_count ASC, loss_count DESC", "win_count DESC, tie_count DESC, loss_count ASC" },
    { "units_killed ASC",                              "units_killed DESC" },
    { "units_lost ASC",                                "units_lost DESC" },
    { "units_ratio ASC",                               "units_ratio DESC" },
    { "damage_given ASC",                              "damage_given DESC" },
    { "damage_taken ASC",                              "damage_taken DESC" },
    { "damage_ratio ASC",                              "damage_ratio DESC" },
];

// NOTE: Structure can be entire default init if given user auth is not found
// Tokens can be empty if not yet generated
public struct UserLoginTokens
{
    bool valid = false;
    int user_id = -1;
    string nick_name = "";
    string user_name_token = ""; // empty if not present
    string password_token = "";  // empty if not present
};


public interface WWWDataStoreInterface
{
	User user(int user_id);    
    Game game(int game_id);
    
    // Sorted by game date time descending
    // Also returns the total count of games
	// NOTE: Set user_id to a non-negative number to filter only that user's games
    GameList[] games(int limit_offset, int limit_range, ref int count, int user_id = -1);

    Tournament tournament(string short_name);
    Tournament[] tournaments(bool limit_recent = true);
    TournamentRound tournament_round(int round_id);

    // Sorted by the date of the first game in the round
    TournamentRoundList[] tournament_rounds(int tournament_id);

    // Sorted by game date/time ascending
    GameList[] tournament_round_games(int round_id, int limit_offset = 0, int limit_range = int.max);

    // Pass -1 for round_id to aggregate over all rounds in the tournament
    PlayerStats[] tournament_player_stats(int tournament_id, int round_id,
                                          PlayerStatsColumn order = PlayerStatsColumn.WinTieLoss,
                                          bool order_descending = true);

    // All of these return the new ID, or -1 on failure
    int create_tournament(string tournament_name, string tournament_short_name);
    int create_tournament_round(int tournament_id, string round_name);
    int create_tournament_round_game(int round_id, int game_id);
    
    UserLoginTokens user_login_tokens(uint64_t steam_id);
    int create_steam_user(uint64_t steam_id, string nick_name, string team_name);    
};



//-------------------------------------------------------------------------------------------------
public class WWWDataStoreNull : WWWDataStoreInterface
{
	public User user(int user_id)
    {
        User user;
        return user;
    }

    public GameList[] games(int limit_offset, int limit_range, ref int count, int user_id = -1)
    {
        auto games = new GameList[0];
        return games;
    }

    public Game game(int game_id)
    {
        Game game;
        return game;
    }

    public Tournament[] tournaments(bool limit_recent = true)
    {
        return new Tournament[0];
    }

    public Tournament tournament(string short_name)
    {
        return Tournament();
    }

    public int create_tournament(string tournament_name, string tournament_short_name)
    {
        return -1;
    }

    public int create_tournament_round(int tournament_id, string round_name)
    {
        return -1;
    }

	public int create_tournament_round_game(int round_id, int game_id)
    {
        return -1;
    }

    public TournamentRoundList[] tournament_rounds(int tournament_id)
    {
        return new TournamentRoundList[0];
    }

    public TournamentRound tournament_round(int round_id)
    {
        return TournamentRound();
    }

    public GameList[] tournament_round_games(int round_id, int limit_offset = 0, int limit_range = int.max)
    {
        return new GameList[0];
    }

    public PlayerStats[] tournament_player_stats(int tournament_id, int round_id,
                                                 PlayerStatsColumn order = PlayerStatsColumn.WinTieLoss,
                                                 bool order_descending = true)
    {
        return new PlayerStats[0];
    }

    public UserLoginTokens user_login_tokens(uint64_t steam_id)
    {
        return UserLoginTokens();
    }

    public int create_steam_user(uint64_t steam_id, string nick_name, string team_name)
    {
        return -1;
    }
};



//-------------------------------------------------------------------------------------------------
public class WWWDataStoreMysql : WWWDataStoreInterface
{
    this(string database_connection_string)
    {
        m_db = new MySQLClient(database_connection_string);
    }

    User user(int user_id)
    {
        auto db = m_db.lockConnection();

        User result;
        bool not_found = true;

        string message = "";        // TODO: Could use appender, but good enough
        db.execute(
                "SELECT
                    metaserver_users.nick_name AS nick_name,
                    DATE_FORMAT(metaserver_users.last_login_datetime, '%Y-%m-%d %H:%i:%S') AS last_login_datetime,
                    metaserver_login_tokens.steam_id AS steam_id
                FROM metaserver_users
                LEFT JOIN metaserver_login_tokens ON metaserver_users.id = metaserver_login_tokens.user_id
                WHERE metaserver_users.id = ?;", user_id, (MySQLRow row) {

            not_found = false;

            result.nick_name              = row.nick_name.get!string;
            result.last_login_date_string = row.last_login_datetime.isNull ? "" : row.last_login_datetime.get!string;
            // NOTE: We encode this here for simplicity, but should eventually move to a utility function somewhere
            result.steam_profile_url      = row.steam_id.isNull ? "" : ("https://steamcommunity.com/profiles/" ~ to!string(row.steam_id.get!uint64_t) ~ "/");
        });

        if (not_found)
            throw new HTTPStatusException(HTTPStatus.notFound);

        return result;
    }

    GameList[] games(int limit_offset, int limit_range, ref int count, int user_id = -1)
    {
        auto db = m_db.lockConnection();

		string sql_from_where = "
			FROM metaserver_games
				INNER JOIN metaserver_scorings ON metaserver_games.scoring = metaserver_scorings.scoring";
		if (user_id >= 0)
		{
			sql_from_where ~= "
				INNER JOIN metaserver_games_teams ON metaserver_games.id = metaserver_games_teams.metaserver_games_id
				INNER JOIN metaserver_games_teams_players ON metaserver_games_teams.id = metaserver_games_teams_players.metaserver_games_teams_id
				WHERE metaserver_games_teams_players.user_id = ?";
		}

		string sql = "
            SELECT
				DATE_FORMAT(metaserver_games.start_datetime, '%Y-%m-%d %H:%i:%S') AS start_date_string,
				metaserver_games.map_name as map_name,
				metaserver_games.player_count as player_count,
				metaserver_games.recording_file_name as recording_file_name,
				metaserver_scorings.scoring_name as scoring_name,
				TIME_FORMAT(SEC_TO_TIME(metaserver_games.duration / 30.0), '%H:%i:%S') as duration_string,
				metaserver_games.id as game_id" ~
			sql_from_where ~ "
			ORDER BY metaserver_games.start_datetime DESC
            LIMIT ?, ?;";

        string count_sql = "SELECT COUNT(*) AS count" ~ sql_from_where;

        GameList[] games;
		if (user_id >= 0)
		{
            db.execute(count_sql, user_id, (MySQLRow row) {
                count = row.count.get!int;
            });
            db.execute(sql, user_id, limit_offset, limit_range, (MySQLRow row) {
                games ~= row.toStruct!(GameList, Strict.yesIgnoreNull);
            });
		}
		else
        {
            db.execute(count_sql, (MySQLRow row) {
                count = row.count.get!int;
            });
            db.execute(sql, limit_offset, limit_range, (MySQLRow row) {
                games ~= row.toStruct!(GameList, Strict.yesIgnoreNull);
            });
        }
        return games;
    }

    Game game(int game_id)
    {
        auto db = m_db.lockConnection();

        Game game;
        bool not_found = true;

        // General game info query
        db.execute(
                "SELECT
                    metaserver_games.map_name AS map_name,
                    metaserver_scorings.scoring_name AS scoring_name,
                    metaserver_difficulty_levels.difficulty_name AS difficulty_name,
                    TIME_FORMAT(SEC_TO_TIME(time_limit / 30.0), '%H:%i:%S') AS time_limit_string,
                    TIME_FORMAT(SEC_TO_TIME(planning_time_limit / 30.0), '%H:%i:%S') AS planning_time_limit_string,
                    DATE_FORMAT(start_datetime, '%Y-%m-%d %H:%i:%S') AS start_date,
                    TIME_FORMAT(SEC_TO_TIME(duration / 30.0), '%H:%i:%S') AS duration_string,
                    metaserver_games.recording_file_name AS recording_file_name,
                    metaserver_games.cooperative AS cooperative,
                    metaserver_games.allow_teams AS allow_teams,
                    metaserver_games.allow_unit_trading AS allow_unit_trading,
                    metaserver_games.allow_veterans AS allow_veterans,
                    metaserver_games.allow_alliances AS allow_alliances,
                    metaserver_games.overhead_map AS overhead_map,
                    metaserver_games.deathmatch AS deathmatch,
                    metaserver_games.vtfl AS vtfl,
                    metaserver_games.anti_clump AS anti_clump,
                    metaserver_games.time_limit AS time_limit,
                    metaserver_games.planning_time_limit AS planning_time_limit
                FROM metaserver_games
                    INNER JOIN metaserver_scorings ON metaserver_games.scoring = metaserver_scorings.scoring
                    INNER JOIN metaserver_difficulty_levels ON metaserver_games.difficulty = metaserver_difficulty_levels.difficulty
                WHERE metaserver_games.id = ?", game_id, (MySQLRow row) {
            not_found = false;

            // TODO: We can probably come up with a fancy way to use toStruct here, but given nested structures
            // we're going to just keep it simple and explicit for now.
            game.map_name                       = row.map_name.get!string;
            game.scoring_name                   = row.scoring_name.get!string;
            game.difficulty_name                = row.difficulty_name.get!string;
            game.time_limit_string              = row.time_limit_string.get!string;
            game.planning_time_limit_string     = row.planning_time_limit_string.get!string;
            game.start_date                     = row.start_date.get!string;
            game.duration_string                = row.duration_string.get!string;
            game.recording_file_name            = row.recording_file_name.get!string;
            game.cooperative                    = row.cooperative.get!bool;
            game.allow_teams                    = row.allow_teams.get!bool;
            game.allow_unit_trading             = row.allow_unit_trading.get!bool;
            game.allow_veterans                 = row.allow_veterans.get!bool;
            game.allow_alliances                = row.allow_alliances.get!bool;
            game.overhead_map                   = row.overhead_map.get!bool;
            game.deathmatch                     = row.deathmatch.get!bool;
            game.vtfl                           = row.vtfl.get!bool;
            game.anti_clump                     = row.anti_clump.get!bool;
            game.time_limit                     = row.time_limit.get!int;
            game.planning_time_limit            = row.planning_time_limit.get!int;
        });

        if (not_found)
            throw new HTTPStatusException(HTTPStatus.notFound);
        
        // Get player and team info
        // We can either do this team by team or all at once with a DB join
        // We pick the latter for now to avoid unnecessary serialization
        {
            // NOTE: Sort order in this query is actually very important for the logic in game() below!
            // i.e. team-based sorting *must* be the top level criteria (team players must be contiguous)
            
            // NOTE: We leave the left join in even if they don't provide a tournament game ID (i.e. it's -1)
            // This is in theory slightly less efficient for non-tournament games but the difference is unmeasurable
            // so we'll leave it here in all cases for simplicity.

            // Player sorting (as consistent with Myth as possible):
            // Captain, kills, damage
            // NOTE: Should we sort dropped players to the bottom?

            // Lazily separate teams by noticing team_id changing in the joined rows
            Game.Team team;
            int current_team_id = -1;

            db.execute(
                    "SELECT
                        metaserver_games_teams.id AS team_id,
                        metaserver_games_teams.place AS place,
                        metaserver_games_teams.place_tie AS place_tie,
                        metaserver_games_teams.spectators AS spectators,
                        metaserver_games_teams.eliminated AS eliminated,
                        metaserver_games_teams.team_name AS team_name,
                        metaserver_games_teams_players.nick_name AS nick_name,
                        (CASE WHEN metaserver_games_teams_players.user_id IS NULL THEN -1 ELSE metaserver_games_teams_players.user_id END) as user_id,
                        (CASE WHEN metaserver_games_teams_players.user_id IS NULL THEN TRUE ELSE FALSE END) AS guest,
                        metaserver_games_teams_players.units_killed AS units_killed,
                        metaserver_games_teams_players.units_lost AS units_lost,
                        metaserver_games_teams_players.damage_given AS damage_given,
                        metaserver_games_teams_players.damage_taken AS damage_taken,
                        metaserver_games_teams_players.host AS host,
                        metaserver_games_teams_players.captain AS captain,
                        metaserver_games_teams_players.dropped AS dropped
                    FROM metaserver_games_teams_players
                        INNER JOIN metaserver_games_teams ON metaserver_games_teams_players.metaserver_games_teams_id = metaserver_games_teams.id
                    WHERE metaserver_games_teams.metaserver_games_id = ?
                    ORDER BY
                        metaserver_games_teams.spectators ASC,
                        metaserver_games_teams.place ASC,
                        metaserver_games_teams.id ASC,
                        metaserver_games_teams_players.captain DESC,
                        metaserver_games_teams_players.units_killed DESC,
                        metaserver_games_teams_players.damage_given DESC;", game_id, (MySQLRow row) {

                // Check if we need to start a new "team"
                int team_id = row.team_id.get!int;
                if (team_id != current_team_id)
                {
                    if (current_team_id >= 0)
                        game.teams ~= team;
                    current_team_id = team_id;

                    // Again there's probably a fancy way to use toStruct here, but leave it for now due to nested structure
                    team = Game.Team.init;
                    team.place           = row.place.get!int;
                    team.place_tie       = row.place_tie.get!bool;
                    team.spectators      = row.spectators.get!bool;
                    team.eliminated      = row.eliminated.get!bool;
                    team.team_name       = row.team_name.get!string;

                    //team.players = new Game.Player[0];
                }

                Game.Player player = row.toStruct!(Game.Player, Strict.yesIgnoreNull);

                team.players ~= player;
                team.units_killed += player.units_killed;
                team.units_lost   += player.units_lost;
                team.damage_given += player.damage_given;
                team.damage_taken += player.damage_taken;

                // TODO: Notice the host's nick name as we go through and set it in a top level field?
            });

            // Final team
            if (current_team_id >= 0)
                game.teams ~= team;
        }

        return game;
    }

    Tournament[] tournaments(bool limit_recent = true)
    {
        // Almost every page has a call here for the recent tournaments dropdown, so it's worth catching any
        // DB errors here and logging.
        try
        {
            auto db = m_db.lockConnection();

            Tournament[] tournaments;
            db.execute(
                    "SELECT tournament_id, organizer_user_id, tournament_name AS name, tournament_short_name AS short_name, DATE_FORMAT(created_datetime, '%b %Y') AS start_month_string
                    FROM metaserver_tournaments
                    ORDER BY created_datetime DESC" ~ (limit_recent ? " LIMIT 5;" : ";"), (MySQLRow row) {
                tournaments ~= row.toStruct!Tournament;
            });            
            return tournaments;
        }
        catch (Exception e)
        {
            log_message("Error querying database for tournaments: %s", e.msg);
            throw e;
        }
    }

    Tournament tournament(string short_name)
    {
        auto db = m_db.lockConnection();

        Tournament tournament;
        db.execute(
                "SELECT tournament_id, organizer_user_id, tournament_name AS name, tournament_short_name AS short_name, DATE_FORMAT(start_date, '%b %Y') AS start_month_string
                FROM metaserver_tournaments
                WHERE tournament_short_name = ?", short_name, (MySQLRow row) {
            tournament = row.toStruct!Tournament;
        });
        return tournament;
    }

    TournamentRoundList[] tournament_rounds(int tournament_id)
    {
        auto db = m_db.lockConnection();

        // Bit fancy due to sorting based on games contained in the round
        TournamentRoundList[] rounds;
        db.execute(
                "SELECT
                    metaserver_tournaments_rounds.round_id AS round_id,
                    metaserver_tournaments_rounds.round_name AS name,
                    COUNT(metaserver_tournaments_rounds_games.game_id) AS game_count,
                    DATE_FORMAT(MIN(metaserver_games.start_datetime), '%Y-%m-%d') AS start_date_string
                FROM metaserver_tournaments_rounds
                    LEFT JOIN metaserver_tournaments_rounds_games ON metaserver_tournaments_rounds.round_id = metaserver_tournaments_rounds_games.round_id
                    LEFT JOIN metaserver_games ON metaserver_games.id = metaserver_tournaments_rounds_games.game_id
                WHERE tournament_id = ?
                GROUP BY metaserver_tournaments_rounds.round_id
                ORDER BY
                    (CASE WHEN metaserver_games.start_datetime IS NULL THEN 1 ELSE 0 END),
                    metaserver_games.start_datetime ASC;", tournament_id, (MySQLRow row) {
            rounds ~= row.toStruct!(TournamentRoundList, Strict.yesIgnoreNull);
        });
        return rounds;
    }

    TournamentRound tournament_round(int round_id)
    {
        auto db = m_db.lockConnection();

        TournamentRound round;
        bool not_found = true;

        db.execute(
                "SELECT
                    metaserver_tournaments.tournament_id AS tournament_id,
                    metaserver_tournaments_rounds.round_id AS round_id,
                    metaserver_tournaments_rounds.round_name AS name
                FROM metaserver_tournaments_rounds
                    INNER JOIN metaserver_tournaments ON metaserver_tournaments_rounds.tournament_id = metaserver_tournaments.tournament_id
                WHERE
                    metaserver_tournaments_rounds.round_id = ?;", round_id, (MySQLRow row) {
            not_found = false;
            round = row.toStruct!TournamentRound;
        });

        if (not_found)
            throw new HTTPStatusException(HTTPStatus.notFound);

        return round;
    }

    GameList[] tournament_round_games(int round_id, int limit_offset = 0, int limit_range = int.max)
    {
        auto db = m_db.lockConnection();

        GameList[] games;
        db.execute(
                "SELECT
                    DATE_FORMAT(metaserver_games.start_datetime, '%Y-%m-%d %H:%i:%S') AS start_date_string,
                    metaserver_games.map_name as map_name,
                    metaserver_games.player_count as player_count,
                    metaserver_games.recording_file_name as recording_file_name,
                    metaserver_scorings.scoring_name as scoring_name,
                    TIME_FORMAT(SEC_TO_TIME(metaserver_games.duration / 30.0), '%H:%i:%S') as duration_string,
                    metaserver_games.id as game_id
                FROM metaserver_tournaments_rounds_games
                    INNER JOIN metaserver_tournaments_rounds ON metaserver_tournaments_rounds_games.round_id = metaserver_tournaments_rounds.round_id
                    INNER JOIN metaserver_games ON metaserver_tournaments_rounds_games.game_id = metaserver_games.id
                    INNER JOIN metaserver_scorings ON metaserver_games.scoring = metaserver_scorings.scoring
                WHERE metaserver_tournaments_rounds.round_id = ?
                ORDER BY start_datetime ASC
                LIMIT ?, ?;", round_id, limit_offset, limit_range, (MySQLRow row) {
            games ~= row.toStruct!(GameList, Strict.yesIgnoreNull);
        });
        return games;
    }

    PlayerStats[] tournament_player_stats(int tournament_id, int round_id,
                                          PlayerStatsColumn order = PlayerStatsColumn.WinTieLoss,
                                          bool order_descending = true)
    {
        auto db = m_db.lockConnection();

        // NOTE: Always hide likely spectators (no damage and not captain)
        // WARNING: units_ratio and damage_ratio come back as NEWDECIMAL, which doesn't autoconvert in toStruct
        // Thus we just work around this by avoiding storing them directly in the structure and instead computing them
        // on the fly where needed (they are simply derived values anyways).
        string sql =
            "SELECT 
                user_id, nick_name,
                CAST(SUM(units_killed) AS SIGNED) AS units_killed, 
                CAST(SUM(units_lost) AS SIGNED) AS units_lost,
                CAST(SUM(damage_given) AS SIGNED) AS damage_given,
                CAST(SUM(damage_taken) AS SIGNED) AS damage_taken,
                CAST(SUM(win) AS SIGNED) AS win_count,
                CAST(SUM(loss) AS SIGNED) AS loss_count,
                CAST(SUM(tie) AS SIGNED) AS tie_count,
                SUM(units_killed) / GREATEST(1, SUM(units_lost)) AS units_ratio,
                SUM(damage_given) / GREATEST(1, SUM(damage_taken)) AS damage_ratio
            FROM metaserver_tournaments_players_stats_view stats
            WHERE (captain OR units_killed > 0 OR units_lost > 0 OR damage_given > 0 OR damage_taken > 0)
                AND tournament_id = ?
            ";

        if (round_id > 0)
            sql ~= "AND round_id = " ~ to!string(round_id);     // Just to avoid variable argument list for now...

        // Parameterized sorting
        string order_string = order_descending ?
            k_player_stats_column_order[order].desc : k_player_stats_column_order[order].asc;
        sql ~= "
            GROUP BY user_id
            ORDER BY " ~ order_string ~ ";";

        PlayerStats[] stats;
        db.execute(sql, tournament_id, (MySQLRow row) {
            stats ~= row.toStruct!PlayerStats;
        });
        return stats;
    }
    
    int create_tournament(string tournament_name, string tournament_short_name)
    {
		try
        {
            auto db = m_db.lockConnection();
            db.execute("INSERT INTO metaserver_tournaments (tournament_name, tournament_short_name) VALUES (?, ?);",
                       tournament_name, tournament_short_name);
            if (db.affected() > 0)
                return cast(int)db.insertID;
        }
		catch (Exception e)
		{
			log_message("Error creating tournament: %s", e.msg);
		}
        return -1;
    }

    int create_tournament_round(int tournament_id, string round_name)
    {
		try
        {
            auto db = m_db.lockConnection();
            db.execute("INSERT INTO metaserver_tournaments_rounds (tournament_id, round_name) VALUES (?, ?);",
                       tournament_id, round_name);
            if (db.affected() > 0)
                return cast(int)db.insertID;
        }
		catch (Exception e)
		{
			log_message("Error creating tournament round: %s", e.msg);
		}
        return -1;
    }

	int create_tournament_round_game(int round_id, int game_id)
    {
		try
        {
            auto db = m_db.lockConnection();
            db.execute("INSERT INTO metaserver_tournaments_rounds_games (round_id, game_id) VALUES (?, ?);",
                       round_id, game_id);
            if (db.affected() > 0)
                return cast(int)db.insertID;
        }
		catch (Exception e)
		{
			log_message("Error creating tournament: %s", e.msg);
		}
        return -1;
    }

    UserLoginTokens user_login_tokens(uint64_t steam_id)
    {
        auto db = m_db.lockConnection();

        UserLoginTokens tokens;
        db.execute(
                "SELECT
                    TRUE AS valid,
                    metaserver_login_tokens.user_id AS user_id,
                    metaserver_users.nick_name AS nick_name,
                    metaserver_login_tokens.user_name_token AS user_name_token,
                    metaserver_login_tokens.password_token AS password_token
                FROM metaserver_login_tokens
                    INNER JOIN metaserver_users ON (metaserver_login_tokens.user_id = metaserver_users.id)
                WHERE metaserver_login_tokens.steam_id = ?;", steam_id, (MySQLRow row) {
            tokens = row.toStruct!(UserLoginTokens, Strict.yesIgnoreNull);
        });        
        return tokens;
    }

    private string generate_random_password(int char_count)
    {
        // All ansi characters, so single utf8 code point
        auto password = new char[char_count];

        foreach (ref c; password)
        {
            // Could do lots of stuff here to add randomness, but this is sufficient for now
            c = cast(char)uniform('a', 'z'+1);
        }

        return cast(string)password;
    }

    // Create a new user linked to the given steam user
    // Returns new user_id (or -1 on failure)
    int create_steam_user(uint64_t steam_id, string nick_name, string team_name)
    {
        auto db = m_db.lockConnection();

        // TODO: This should likely all be wrapped in a transaction to avoid orphaned metaserver
        // users if there's some error in the second insertion (i.e. duplicate steam ID or similar).
        // Technically the frontend will tend to prevent this, but still should be more robust here.

        // TEXT fields aren't allowed to have defaults in the database, so set them here...
        db.execute("INSERT INTO metaserver_users (nick_name, team_name, city, state, country, quote) VALUES (?, ?, '', '', '', '');",
                    nick_name, team_name);

        if (db.affected() > 0)
        {
            int user_id = cast(int)db.insertID;

            string user_name_token = "u" ~ to!string(user_id);
            string password_token = generate_random_password(6);

            db.execute("INSERT INTO metaserver_login_tokens (user_id, steam_id, user_name_token, password_token) VALUES (?, ?, ?, ?)",
                       user_id, steam_id, user_name_token, password_token);

            if (db.affected() > 0)
                return user_id;
            else
                log_message("WWWDataStore: Failed to create new metaserver_login_token row (duplicate steam ID?)!");
        }
        else
            log_message("WWWDataStore: Failed to create new metaserver_user row!");

        // Failed on fallthrough
        return -1;
    }

    // NOTE: Be a bit careful with state here. These functions can be re-entrant due to
    // triggering blocking calls and then having other requests submitted by separate fibers.
    // This it's safest to keep all of this state immutable.

    // This is internally a connection pool, so safe to use here
    private MySQLClient m_db;
};