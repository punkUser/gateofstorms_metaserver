module game;

import exceptions;
import myth_socket;
import room_client;
import endian;
import log;
import private_api;
import game_recording;

import vibe.data.json;

import std.string;
import std.conv;
import std.bitmanip;
import std.algorithm;
import std.stdio;
import std.random;
import std.datetime.stopwatch : StopWatch, AutoStart;
import std.datetime;
import std.file;
import std.array;

private enum
{
	MAXIMUM_PLAYER_NAME_LENGTH = 31,
	//MAXIMUM_PLAYERS_PER_MAP= 16,      // Currently unused, and has some modifications in client so be careful!
	MAXIMUM_TEAM_NAME_LENGTH= 31,
	MAXIMUM_TEAMS_PER_MAP= 16
};

// Game data
//-------------------------------------------------------------------------------------------------
private enum
{
	_game_option_random_endgame_countdown_bit, // game ends with random, undisplayed countdown
	_game_option_allow_multiplayer_teams_bit, // allow teams of more than one player
	_game_option_limited_visibility_bit, // can't see guys too far away
	_game_option_no_ingame_rankings_bit, // don't display ingame (F7) rankings

	_game_option_allow_unit_trading_bit, // allow pregame unit shuffling
	_game_option_allow_veterans_bit, // allow veterans surviving from previous map to replace units on this map
	_game_option_continuation_bit, // don't wipe permanent stats, etc.
	_game_option_cooperative_bit, // cooperative net play (whee!)

	_game_option_random_teams_bit,
	_game_option_limited_terrain_visibility_bit,
	_game_option_camera_tracking_initially_on_bit,
	//_game_option_unused_bit, // Build 372 - ALS - used to be _game_option_paused_bit, never used on game->option_flags
	_game_option_netgame_cutscenes_bit, // Build 409 - DRB - reused this bit - show cutscenes in coop.

	_game_option_unused2_bit, // Build 372 - ALS - used to be _game_option_local_time_paused_bit, never used on game->option_flags 	
	_game_option_allow_alliances_bit, // allow in-game alliances
	_game_option_allow_overhead_map_bit,  // allow players to use the overhead map
	_game_option_order_game_bit,

	_game_option_server_is_observer_bit,
	_game_option_restore_veterans_bit,
	_game_option_patch_version_bit0,
	_game_option_patch_version_bit1,

	_game_option_deathmatch_bit,
	_game_option_uses_tfl_bit,
	_game_option_uses_anticlump_bit,
	_game_option_team_captain_chosen_bit,

	// Build 273 - ALS - there was actually no more rooms for new flags,
	//                   but metaserver_hosted wasn't being used, so we're
	//                   re-using it for 1.5.1 compat
	_game_option_version_151_bit,

	_game_option_version_unused1_bit, // Build 300 - ALS - was _game_option_version_13_bit
	_game_option_version_unused2_bit, // Build 300 - ALS - was _game_option_version_14_bit
	_game_option_version_unused3_bit, // Build 300 - ALS - was _game_option_version_14x_bit
	_game_option_version_unused4_bit, // Build 300 - ALS - was _game_option_version_150_bit

	_game_option_version_modifier_bit, // Build 346 - ALS - was _game_option_version_157_bit (demo films)

	_game_option_has_captains_bit,   // Build 239 - ACS
	// Build 273 - ALS - Another hit, and she's done for! (there's no more room for these)

	NUMBER_OF_GAME_OPTION_FLAGS
};

private struct player_appearance_data
{
	short coat_of_arms_bitmap_index;
	short caste_bitmap_index;

	ubyte[MAXIMUM_PLAYER_NAME_LENGTH+1] name;
	ubyte[MAXIMUM_TEAM_NAME_LENGTH+1] team_name;

	rgb_color primary_color;
	rgb_color secondary_color;
};

private struct new_player_data
{
	short team_index;
	short type;
	ushort flags;
	short order;
	uint team_captain_identifier;
	uint unique_identifier;

	int agreed_to_play;
	int team_is_locked;

	uint metaserver_player_id;
	byte metaserver_player;
	byte persistent_ready;
	short game_version;
	short build_number;
	short[3] unused2;

	player_appearance_data appearance;
};

private struct new_game_parameter_data
{
	short type;
	short scoring;
	uint option_flags;
	int time_limit;
	uint scenario_tag;
	short difficulty_level;
	short maximum_players;
	ushort initial_team_random_sead;
	short maximum_teams;
	uint random_seed;
	int pregame_time_limit;
	int[2] unused;
	short unused_short;
	short plugin_count;
	byte[512] plugin_data;
};

private struct metaserver_game_description
{
	new_game_parameter_data parameters;
	int public_tags_checksum;
	int private_tags_checksum;
	ushort flags;
	byte player_count;
};

/* Currently unused
private struct new_game_data
{
	new_game_parameter_data parameters;

	short player_count;
	short local_player_index;
	new_player_data[MAXIMUM_PLAYERS_PER_MAP] players;

	uint[3] unused;
};
*/


// Postgame score report
//-------------------------------------------------------------------------------------------------
private enum
{
	_game_ended_normally,
	_game_ended_with_server_loss,
	_game_ended_with_player_quit,
	NUMBER_OF_GAME_ENDED_CODES,
};

private enum
{
	_game_scoring_attrition= 0, // most kill-points wins (game will end after a certain period of inactivity or if further play would not change the rankings)
	_game_scoring_steal_the_bacon, // [must have time limit] last guy to own the token wins (a neutral or contested ball does not end the game)
	_game_scoring_last_man_on_the_hill, // [must have time limit] last guy to own the flag wins (a neutral or contested flag does not end the game)
	_game_scoring_scavenger_hunt, // first team to touch all the balls wins
	_game_scoring_flag_rally, // first team to touch all the flags wins
	_game_scoring_capture_the_flag, // each team must own or be contesting at least one flag to remain alive (scored by kill-points)
	_game_scoring_balls_on_parade, // each team must own or be contesting at least one ball to remain alive (scored by kill-points)
	_game_scoring_territories, // [must have time limit] team with the most flags at endgame wins (ties due to contested or neutral flags do not end the game)
	_game_scoring_captures, // [must have time limit] team with the most balls at endgame wins (ties due to contested or neutral balls do not end the game)
	_game_scoring_king_of_the_hill, // [must have time limit]most time on hill wins (was royalty)
	_game_scoring_cattle_drive, // score by taking your marked units into the opponents end zone
	_game_scoring_assassination,
	_game_scoring_hunting,
	_game_scoring_custom, // map actions determine endgame
	_game_scoring_king_of_the_hill_tfl, // [must have time limit]most time on hill wins (was royalty)
	_game_scoring_king_of_the_map, // Build 411: uses terries flags and weighted KOTH-style scoring based on # owned
	NUMBER_OF_GAME_SCORING_TYPES,
}

// English game mode names (for JSON feed)
public immutable string[NUMBER_OF_GAME_SCORING_TYPES] game_scoring_names =
[
	"Body Count",
	"Steal the Bacon",
	"Last Man on the Hill",
	"Scavenger Hunt",
	"Flag Rally",
	"Capture the Flag",
	"Balls On Parade",
	"Territories",
	"Captures",
	"King of the Hill",
	"Stampede!",
	"Assassin",
	"Hunting",
	"Custom",
	"King of the Hill (TFL)",
	"King of the Map",
];

public struct bungie_net_game_standings_team
{
	short place; // (zero is first place, one is second, etc.)

	short captain_player_index;
	short team_valid_flag; // FALSE if there were no players on this team and it should be ignored

	short team_eliminated_flag; // TRUE if all of this teams units were wiped out
	int time_of_elimination; // <=actual_time_elapsed (only valid if the team was eliminated) - ATL: This doesn't seem to be sent correctly from myth
};

public struct bungie_net_game_standings_player
{
	short team_index; // irrelevant except it matches other players on the same team

	short player_finished_game_flag; // FALSE if this player was dropped (for any reason) before the game ended
	int time_played; // <=actual_time_elapsed (only valid if the player did not finish the game) - ATL: This doesn't seem to be sent correctly from myth

	int units_killed, units_lost;
	int points_killed, points_lost;

	int bungie_net_player_id;
};

public struct bungie_net_game_standings
{
	short game_ended_code;

	short game_scoring;
	int game_version;

	int time_limit, actual_time_elapsed;

	int bungie_net_player_id; // the player_id reporting these standings

	short number_of_players; // who started the game
	short number_of_teams; // who started the game
	bungie_net_game_standings_team[MAXIMUM_TEAMS_PER_MAP] teams;

    // NOTE: Removed from this structure since it now has variable length
	//bungie_net_game_standings_player[MAXIMUM_PLAYERS_PER_MAP] players;
};



public class Game
{
	public this(int room_type, int host_user_id, int host_address_ipv4, ushort host_port, in ubyte[] game_data)
	{
		m_game_result = new GameResult();
		m_game_result.room_type = room_type;

		m_host_user_id = host_user_id;
		m_host_address_ipv4 = host_address_ipv4;
		m_host_port = host_port;

		m_game_in_progress = false;

		update_game_data(game_data);
	}

	// Makes an internal copy of the game data
	public void update_game_data(in ubyte[] game_data)
	{
		if (game_data.length > MAXIMUM_METASERVER_GAME_DATA_SIZE)
			throw new ClientProtocolException("Game data is too large");

		m_game_data = game_data.dup;
	}

    // NOTE: If game is in progress this will append to the list, otherwise replace it
	public void update_player_list(in PlayerData[] player_data)
	{
        if (!m_game_in_progress)
            m_game_player_data.clear();

		// Fill in the player data for use later when submitting scores, indexed by user ID
		foreach (p; player_data)
			m_game_player_data[p.user_id] = p;
	}

	// This costs something, so we do it only on demand
	public metaserver_game_description decode_game_info(ref string game_name, ref string map_name) const
	{
		metaserver_game_description desc;
		MythSocket.decode_payload(m_game_data, desc, game_name, map_name);
		return desc;
	}

	public void start(int game_time_in_seconds)
	{
		// Start timing so that we know approximately how long until the game is over
		// NOTE: Convert "0" to NONE (-1; "untimed") here. Wacky, but this is how coops seem to work.
		m_total_game_time_seconds = game_time_in_seconds > 0 ? game_time_in_seconds : -1;
		m_game_elapsed_time.reset();
		m_game_elapsed_time.start();

		// Reset recording stuff
		m_game_result.recording_file_name = "";

		// Time to decode the game data and set up for storing results later
		string game_name;
		string map_name;
		auto desc = decode_game_info(game_name, map_name);

		m_game_in_progress = true;
		m_game_result.game_name = game_name;
		m_game_result.map_name = map_name;
		m_game_result.scoring = desc.parameters.scoring;
		m_game_result.difficulty = desc.parameters.difficulty_level;
		m_game_result.time_limit = desc.parameters.time_limit;
		m_game_result.planning_time_limit = desc.parameters.pregame_time_limit;

		m_game_result.start_datetime = Clock.currTime().toISOExtString();

		// Decoded options bitfield
		m_game_result.cooperative         = 0 != (desc.parameters.option_flags & (1 << _game_option_cooperative_bit));
		m_game_result.allow_teams         = 0 != (desc.parameters.option_flags & (1 << _game_option_allow_multiplayer_teams_bit));
		m_game_result.allow_unit_trading  = 0 != (desc.parameters.option_flags & (1 << _game_option_allow_unit_trading_bit));
		m_game_result.allow_veterans      = 0 != (desc.parameters.option_flags & (1 << _game_option_allow_veterans_bit));
		m_game_result.allow_alliances     = 0 != (desc.parameters.option_flags & (1 << _game_option_allow_alliances_bit));
		m_game_result.overhead_map        = 0 != (desc.parameters.option_flags & (1 << _game_option_allow_overhead_map_bit));
		m_game_result.deathmatch          = 0 != (desc.parameters.option_flags & (1 << _game_option_deathmatch_bit));
		//m_game_result.host_observer       = 0 != (desc.parameters.option_flags & (1 << _game_option_server_is_observer_bit));
		m_game_result.vtfl                = 0 != (desc.parameters.option_flags & (1 << _game_option_uses_tfl_bit));
		m_game_result.anti_clump          = 0 != (desc.parameters.option_flags & (1 << _game_option_uses_anticlump_bit));
	}

    // Sets relevant field in results - should be called before scores are reported below
    public void set_recording_file_name(string file_name)
    {
        m_game_result.recording_file_name = file_name;
    }

	// Submit scores for the game
	//
	// NOTE: Since this function returns the result to submit to the metaserver API, it is
	// assumed that any streamed recording has already been saved at this point. This is currently
	// true in how myth works, but it's worth calling out this assumption explicitly.
	public GameResult report_scores(in ref bungie_net_game_standings scores, bungie_net_game_standings_player[] players)
	{
		// Keep track of which players we've "used"
		PlayerData[int] game_player_data = m_game_player_data.dup;

        // TODO: This probably needs some updates after midgame joining/rejoining!
        // TODO: Likely de-duplicate player scores up front now
        // These should probably always be equal, but at least should not exceed the size
        assert(scores.number_of_players <= players.length);
		m_game_result.player_count = cast(int)scores.number_of_players;

		// Fill in overall game result data
		m_game_result.ended_code = scores.game_ended_code;
		m_game_result.duration = scores.actual_time_elapsed;
		m_game_result.end_datetime = Clock.currTime().toISOExtString();

		// Fill out player and team scores
		m_game_result.teams = [];
		foreach (team_scores; scores.teams[0 .. scores.number_of_teams])
		{
			if (team_scores.team_valid_flag)
			{
				GameResult.Team team;
				team.spectators = false;
				team.eliminated = (team_scores.team_eliminated_flag != 0);

				// NOTE: We mess with the result in one way here...
				// If it's a coop game, then we assign the team "1st" only if the game ended normally any with a win
				// This simplifies "win/loss" logic on the database side
				team.place = team_scores.place + 1; // Convert from 0-based to 1-based
				// Defer filling out the "place_tie" field until after we have sorted
				if (m_game_result.cooperative)
					team.place = (m_game_result.ended_code != _game_ended_normally) ? 2 : team.place;
			
				// Find the captain and his team_index (treat it like an ID). Then finding all the matching players.
				auto captain_scores = players[team_scores.captain_player_index];
				int captain_user_id = captain_scores.bungie_net_player_id;
				auto team_index = captain_scores.team_index;

				// Alright we need one more check here... if we can't find the claimed captain in the game,
				// just ignore the entire team. This is to try and avoid the issue that it sends us a BS "team"
				// for coop games.
				
				auto captain_data = captain_user_id in game_player_data;
				if (captain_data)
				{
					// For convenience, we'll copy some data to the team structure
					team.team_name = (*captain_data).team_name;

					foreach (player_scores; filter!(x => x.team_index == team_index)(players[0 .. scores.number_of_players]))
					{
						// Stuff can go a bit wacky in coop games, so we need to double-check here that we
						// aren't trying to find some nonsense user (like "Dark" or "Neutral")...
						auto player_data = player_scores.bungie_net_player_id in game_player_data;
						if (player_data)
						{
							GameResult.Player player;
					
							player.host = (player_scores.bungie_net_player_id == host_user_id);
							player.captain = (player_scores.bungie_net_player_id == captain_user_id);
							player.dropped = (player_scores.player_finished_game_flag == 0);

							player.units_killed = player_scores.units_killed;
							player.units_lost = player_scores.units_lost;
							player.damage_given = player_scores.points_killed;
							player.damage_taken = player_scores.points_lost;
						
							player.data = *player_data;

							team.players ~= player;

							// Mark that we've "used" this player
							game_player_data.remove(player_scores.bungie_net_player_id);
						}
                        else
                        {
                            log_message("Client ID %s not found in game player list!", player_scores.bungie_net_player_id);
                        }
					}

					m_game_result.teams ~= team;
				}
                else
                {
                    log_message("Client ID %s of captain not found in game player list!", captain_user_id);
                }
			}
		}

		// Count teams before adding any special teams (spectators)
		m_game_result.team_count = cast(int)m_game_result.teams.length;

		// If we have any players left who are unaccounted-for, put them on a special "spectators" team
		if (game_player_data.length > 0)
		{
			GameResult.Team team;
			team.place = team.place.max; // So they get sorted last
			team.spectators = true;
			team.team_name = "Spectators";
			// Rest default-initiatlized

			foreach (player_data; game_player_data)
			{
				GameResult.Player player;

				player.host = (player_data.user_id == host_user_id);
				player.data = player_data;
				// Rest default-initialized
				
				team.players ~= player;
			}

			m_game_result.teams ~= team;
		}

		// Sort teams by place
		// NOTE: We could slightly optimize this by instead doing an insertion/selection sort as we fill in the
		// results data based on place, but this is plenty good enough for the frequency of game completions.
		sort!("a.place < b.place")(m_game_result.teams);

		// Sort players: put captain first, then sort alphabetically after that
		foreach (ref team; m_game_result.teams)
			sort!("a.captain || (!b.captain && a.data.nick_name < b.data.nick_name)")(team.players);

		// Finally, go back and fill out the "place_tie" field
		auto num_teams = m_game_result.teams.length;
		foreach (i; 0 .. num_teams)
		{
			bool prev_same = (i > 0             ? m_game_result.teams[i].place == m_game_result.teams[i-1].place : false);
			bool next_same = (i < (num_teams-1) ? m_game_result.teams[i].place == m_game_result.teams[i+1].place : false);
			m_game_result.teams[i].place_tie = prev_same || next_same;
		}

		m_game_in_progress = false;
		return m_game_result;
	}

	// Return a big endian stream built from the game data
	public immutable(ubyte)[] game_data_big_endian() const
	{
		// Right now we don't touch this structure at all, so just duplicate it and return
		return m_game_data.idup;
	}


	// Returns 0 if game is not currently in progress
	public int elapsed_time_seconds() const
	{
		// We consider a game to be in progress if it has been started and we haven't yet gotten a result for it
		return m_game_in_progress ? cast(int)m_game_elapsed_time.peek().total!"seconds" : 0;
	}

	public int time_remaining_seconds() const
	{
		// NONE (-1) indicates untimed
		return m_total_game_time_seconds <= 0 ? m_total_game_time_seconds :
			m_total_game_time_seconds - elapsed_time_seconds();
	}
	
	@property public pure nothrow uint host_address_ipv4() const { return m_host_address_ipv4; }
	@property public pure nothrow ushort host_port() const { return m_host_port; }

	@property public pure nothrow int host_user_id() const { return m_host_user_id; }
	@property public pure nothrow bool game_in_progress() const { return m_game_in_progress; }

	private ubyte[] m_game_data;

	private immutable int m_host_user_id;
	private immutable uint m_host_address_ipv4;
	private immutable ushort m_host_port;

	// We store data here about the game for eventual submission to the metaserver API
	private PlayerData[int] m_game_player_data;
	private bool m_game_in_progress; // A game is considered to be "in progress" until scores are submitted
	private GameResult m_game_result;
	private int m_total_game_time_seconds;
	private StopWatch m_game_elapsed_time;
};
