module game_recording;

import exceptions;
import myth_socket;
import endian;
import log;

import vibe.vibe;

import std.file;
import std.conv;
import std.datetime;
import std.format;
import std.random;

private immutable max_recording_command_block_size = 2048; // Must avoid overflowing Myth's read buffer

//-------------------------------------------------------------------------------------------------

private enum
{
	_command_null, // used by the server when no one is giving orders
    _command_sync,
};

private struct command_header
{
	short size; // including this header
	byte verb;
	byte player_index;
	int time;
};

// Just enough of the recording header to see/modify the game end time when we know it
private struct recording_file_header_prefix
{
	short game_version;
	short type;
	int data_offset;
	int recording_ending_time;
};
private union recording_file_header_prefix_union
{
	recording_file_header_prefix header;
	ubyte[recording_file_header_prefix.sizeof] bytes;
};

private struct recording_block_header
{
	uint flags;
	short size; // in bytes
	short command_count;
};
private immutable _block_header_last_flag = 1;

private struct tag_header
{
	short identifier;
	byte flags;
	byte type;
	char[32] name;
	uint group_tag;
	uint subgroup_tag;
	int offset; // actual offset in the file, whether single or monolithic
	int size;
	uint user_data; // user defined
	short ver; // user defined
	byte foundation_tag_file_index; // where a tag will get put when the monolithic files are built
	byte owner_index; // lower is more important (NONE means local folder); invalid on disk
	uint signature;
};
static assert (tag_header.sizeof == 64);



// Returns time in file-name compatible YYYY_MM_DD_HH_MM_SS format
private string get_current_time_filename_string()
{
	auto date_time = cast(DateTime)Clock.currTime();
	auto date = date_time.date;
	auto time = date_time.timeOfDay;
	return format("%04d_%02d_%02d__%02d_%02d_%02d",
				  date.year, date.month, date.day, time.hour, time.minute, time.second);
}


// Records a game stream to disk as received from clients
class GameRecording
{
    // Recordings
	//---------------------------------------------------------------------------------------------

	// Receive recording stream header
	// NOTE: This may come in multiple parts (successive calls)
	public nothrow void append_recording_header(in ubyte[] header)
	{
		// Reset any recording if necessary
		m_recording_game_time = 0;
		m_recording_command_buffer = [];

		m_recording_header ~= header;
	}

	// Receive a recording "command" (currently opaque type)
	public void append_recording_command(in ubyte[] command)
	{
		// If this isn't true we can't save a proper film later...
		// Should never occur except with erronious packets, but we have to test since it could cause
		// an infinite loop in the save code otherwise.
		if (command.length > max_recording_command_block_size)
		{
			throw new ClientProtocolException("Recording command is too large! Got " ~
											  to!string(command.length) ~ ", max " ~ to!string(max_recording_command_block_size));
		}

		command_header header;
		ubyte[] details;
		MythSocket.decode_payload(command, header, details);

		// Null commands update our knowledge of the latest game time, but we do not need to save
		// them to the recording buffer.
		// TODO: Check for out-of-order packets and complain? Shouldn't happen unless client is buggy though.
		m_recording_game_time = header.time;
		if (header.verb == _command_null)
		{
			//log_message("Received null packet, game time %d", header.time);
		}
		else
		{
			// TODO: Probably switch to an appender for efficiency
			m_recording_command_buffer ~= command.dup;
		}
	}

	// End recording stream and save recording
	public NativePath end_recording(int game_time_at_end, int host_user_id, string recordings_path, string recordings_prefix, string recordings_ext)
	{
		// If we never got enough of a header, that's a problem
		if (m_recording_header.length < recording_file_header_prefix.sizeof)
			throw new ClientProtocolException("Recording stream end packet received without sufficient header");

		// TODO: Throw out replays that end before planning time expires?

		m_recording_game_time = game_time_at_end;

		// Patch in game end time to header
		// Remember: anything we change needs to end up big endian!
		// NOTE: We could just poke the four bytes directly (with struct offset), but this works for now
		recording_file_header_prefix_union header_prefix;
		header_prefix.bytes[] = m_recording_header[0 .. header_prefix.bytes.sizeof];
		header_prefix.header.recording_ending_time = native_to_big_endian(game_time_at_end);
		m_recording_header[0 .. header_prefix.bytes.sizeof] = header_prefix.bytes[];

        string recordings_in_progress_path = recordings_path ~ "in_progress/";
		if (!exists(recordings_in_progress_path))
			mkdirRecurse(recordings_in_progress_path);

		// Base name: YYYY-MM-DD HH.MM.SS host_user_id
		// This should really be unique... if the same host does more than one game in 1 second
		// it's probably okay to overwrite...
		string tag_name = get_current_time_filename_string();
		string file_name_string = recordings_prefix ~ tag_name ~ "_" ~ to!string(host_user_id) ~ recordings_ext;
		string full_path_string = recordings_in_progress_path ~ file_name_string;

		// NOTE: File format is all big endian! Data we got across the network is already in
		// this form, but we need to convert anything that we generate here.
        auto file_path = NativePath(full_path_string);
		auto file = vibe.core.file.openFile(file_path, FileMode.createTrunc);

		// Write tag header (info from "recordings" tag group)
		{
			tag_header header;
			// "identifier" not relevant to file on disk
			// flags?
			header.type = 0; // _tag_file_type_local
			assert(tag_name.length < header.name.length);
			header.name[0 .. tag_name.length] = tag_name[];
			header.name[tag_name.length] = 0; // Null terminator
			header.group_tag = 0x7265636F; // 'reco'
			// This just has to be unique. Myth generates random numbers but doesn't guarantee no collisions.
			// Assuming in the long run the metaserver is "unique", just using the game ID works great.
			// But just to hedge our bets, we'll generate random numbers like myth.
			header.subgroup_tag = uniform!uint();
			header.offset = header.sizeof;
			// size?
			// user_data?
			header.ver = 3; // RECORDING_VERSION_NUMBER
			header.owner_index = -1;
			header.signature = 0x6D746832; // 'mth2'

			auto header_big_endian = native_to_big_endian(header);
			file.write((cast(ubyte*)&header_big_endian)[0..tag_header.sizeof]);
		}

		// Write recording header (already big endian)
		file.write(m_recording_header);

		// Now go through the m_recording_command_buffer and combine them into "blocks" that are less than the maximum size
		// that myth can handle, and write out each of those blocks.
		// Always write at least one block even if it has no m_recording_command_buffer (we need to flag it)
		do
		{
			recording_block_header block_header;
			block_header.flags = 0;
			block_header.size = 0;
			block_header.command_count = 0;	
			for (;;)
			{
				if (block_header.command_count >= m_recording_command_buffer.length)
				{
					// Out of commands, mark this as the last block
					block_header.flags = _block_header_last_flag;
					break;
				}
				else if (block_header.size + m_recording_command_buffer[block_header.command_count].length > max_recording_command_block_size)
				{
					// No more space in block
					break;
				}

				block_header.size += m_recording_command_buffer[block_header.command_count].length;
				++block_header.command_count;
			}
			// Either we must be completely out of commands (and thus just need a flagged end block), or we must have
			// consumed at least one command. Otherwise this will loop infinitely.
			assert(m_recording_command_buffer.length == 0 || block_header.command_count > 0);

			// Write out the block header
			auto block_header_big_endian = native_to_big_endian(block_header);
			file.write((cast(ubyte*)&block_header_big_endian)[0..block_header_big_endian.sizeof]);

			// Write out m_recording_command_buffer (already big endian)
			foreach (ref c; m_recording_command_buffer[0 .. block_header.command_count])
				file.write(c);

			// Trim off the m_recording_command_buffer we wrote
			m_recording_command_buffer = m_recording_command_buffer[block_header.command_count .. $];
		} while  (m_recording_command_buffer.length);

		file.close();

		// Cleanup
		m_recording_header = [];
		m_recording_command_buffer = [];

		log_message("Recording saved to %s", file_path.toString());
        return file_path;
	}

    // Recording
	private ubyte[] m_recording_header;
	private ubyte[][] m_recording_command_buffer;
	private int m_recording_game_time;
};