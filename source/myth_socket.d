module myth_socket;

import exceptions;
import encode_packets;
import endian;
import mac_roman;
import log;

import vibe.core.net;

import std.socket;
import std.traits;
import std.conv;
import core.stdc.string;
import std.stdio;
import std.algorithm;
import std.utf;
import std.bitmanip;
import std.datetime;
import std.exception;
import std.random;

// For AF_INET definition
import core.sys.posix.netinet.in_;
version(Windows) import core.sys.windows.winsock2;


public
{
	// Packet constants
	immutable MAXIMUM_METASERVER_APPLICATION_NAME = 31;
	immutable MAXIMUM_METASERVER_BUILD_DATE = 31;
	immutable MAXIMUM_METASERVER_BUILD_TIME = 31;
	immutable NUMBER_OF_SCORING_DATUMS_IN_PLAYER_INFO_PACKET = 36;
	immutable MAXIMUM_METASERVER_GAME_NAME = 31;
	immutable MAXIMUM_METASERVER_GAME_DATA_SIZE = 1024;
	immutable MAXIMUM_METASERVER_PLAYER_DATA_SIZE = 128;
	immutable MAXIMUM_METASERVER_USERNAME = 31;
	immutable MAXIMUM_METASERVER_ORDERNAME = 31;
	immutable MAXIMUM_METASERVER_PASSWORD = 15;
	immutable MOTD_CHANGE_LOGIN_KEY_SIZE = 8;
	immutable MOTD_QUERY_LOGIN_KEY_SIZE = 8;
	immutable MAXIMUM_MOTD_SIZE = 127;
	immutable MAXIMUM_TEAMS_PER_MAP = 16;
	//immutable MAXIMUM_PLAYERS_PER_MAP = 16;
	//immutable MAXIMUM_PLAYERS_PER_METASERVER_HOSTED_GAME = 16;

	// NOTE: This is mainly to avoid overflowing the client's metaserver_globals.buffer
	// Also this must be below 32767 too, as the client uses "shorts" all over the place with packet lengths
	// NOTE: We create some packets on the stack to avoid GC leakage as well, so note that this
	// is a big contributer to fiber stack size requirements. Still, the default of 16MiB on 64-bit
	// is usually plenty.
	immutable MAXIMUM_PACKET_SIZE = 8096;
}


// NOTE: Needs to be > 3 minutes since that's how long the client waits between
// sending keepalive packets when ingame! Ideally should have a buffer on top of
// that as well.
private immutable connection_read_timeout = 10.minutes;


private immutable short METASERVER_PACKET_VERSION = 1;
private immutable short FIRST_CLIENT_PACKET_ID = 100;
private immutable short FIRST_BOTH_PACKET_ID = 200;

public enum packet_type : short
{
	// These are sent from the server
	_room_list_packet= 0,
	_player_list_packet,
	_game_list_packet,
	_server_message_packet,
	_url_packet,
	_data_chunk_packet,
	_password_challenge_packet,
	_user_successful_login_packet,
	_set_player_data_from_metaserver_packet,
	_room_login_successful_packet,
	_message_of_the_day_packet,
	_unused_packet0,
	_send_versions_packet,
	_game_list_pref_packet,
	_player_search_list_packet,
	_buddy_list_packet,
	_order_list_packet,
	_player_info_packet,
	_update_info_packet,
	_update_player_buddy_list_packet,
	_update_order_member_list_packet,
	_you_just_got_blammed_sucka_packet,
	_proxy_client_join_packet,

	// These are sent from the client
	_login_packet= FIRST_CLIENT_PACKET_ID,
	_room_login_packet,
	_logout_packet,
	_set_player_data_packet,
	_create_game_packet,
	_remove_game_packet,
	_change_room_packet,
	_set_player_mode_packet,
	_data_chunk_reply_packet,
	_password_response_packet,
	_request_full_update_packet,
	_game_player_list_packet,
	_game_score_packet,
	_reset_game_packet,
	_start_game_packet,
	_version_control_packet,
	_game_search_query_packet,
	_player_search_query_packet,
	_buddy_query_packet,
	_order_query_packet,
	_update_buddy_packet,
	_player_info_query_packet,
	_update_player_information_packet,

	// Sent by both
	_room_broadcast_packet= FIRST_BOTH_PACKET_ID,
	_directed_data_packet,
	_keepalive_packet,
	_session_key_packet,
	_recording_stream_header_packet,
	_recording_stream_command_packet,
	_recording_stream_end_packet,
};

public struct packet_header
{
	ushort packet_identifier = 0xDEAD;
	packet_type type;
	int length;
};

// Type alias the raw data to the header structure
private union packet_header_union
{
	ubyte[packet_header.sizeof] bytes = void;
	packet_header header;
}

private struct server_message_packet
{
	int error_code;
	char[128] message;
};


// Resolves a network address into an IPv4 address in host byte order
// IPV6 PROBLEM (obviously)
// The goal is to centralize the issue here so that we can find all the places that
// we need to address it in the protocol by extension.
public uint network_address_to_uint_ipv4(NetworkAddress network_address)
{
    // NOTE: sockAddrInt4 will throw if not IPv4 which is what we want
	auto address_ipv4 = network_address.sockAddrInet4().sin_addr.s_addr;
	version (LittleEndian) { return swapEndian(address_ipv4); }
	version (BigEndian)    { return address_ipv4; }
}

// TODO: Remove this and move it to the one usage location
public uint resolve_address_to_ipv4(string remote_address, bool use_dns, out string address_string_ipv4)
{
	auto network_address = resolveHost(remote_address, AF_INET, use_dns);
	address_string_ipv4 = network_address.toAddressString();
	return network_address_to_uint_ipv4(network_address);
}

public uint resolve_address_to_ipv4(string remote_address, bool use_dns = false)
{
	string unused;
	return resolve_address_to_ipv4(remote_address, use_dns, unused);
}

/***
* Provides useful functionality to implement myth's metaserver protocol for sending,
* receiving and encrypting packets. Uses a coroutine style with fiber yields when an
* operation would typically block.
*
* Note that this class does not "own" the socket (hence it being public) so the caller
* is responsible for managing lifetime and destruction.
*/
public class MythSocket
{
	public this(TCPConnection stream)
	{
		m_stream = stream;

		// Disable waiting to combine small packets
		// All of our communication is more latency sensitive than bandwidth
		m_stream.tcpNoDelay = true;

		m_session_key_valid = false;
		m_read_packet_header_valid = false;

		// Work out remote address
        NetworkAddress remote_address = m_stream.remoteAddress();
        m_remote_address_ipv4 = network_address_to_uint_ipv4(remote_address);
		m_remote_address_string = remote_address.toAddressString();

		stream.readTimeout = connection_read_timeout;

		m_session_rng.seed(unpredictableSeed);
	}

	public void negotiate_session_key()
	{
		// Generate a private/public key pair for use with this connection
		generate_public_key(m_server_public_key, m_server_private_key);
		send_packet(packet_type._session_key_packet, m_server_public_key);

		// NOTE: We *require* a session key, since otherwise we'd send passwords in plain text
		m_client_public_key = receive_packet_typed!(encode_packets.key_type)(packet_type._session_key_packet);

		// Generate a session key - all traffic past this point will be encrypted
		generate_session_key(m_client_public_key, m_server_private_key, m_session_key);
		m_session_key_valid = true;
	}

	/***
	* Returns true if any new incoming packet data is available.
	*/
	public bool data_available_for_read() { return m_stream.dataAvailableForRead(); }

	/***
	* "Peeks" at the next packet header but does not receive the payload
	*
	* "Blocks" the calling fiber until the packet header is received, but will yield to the
	* calling fiber when no new data is available in the queue.
	*/
	public packet_header peek_packet_header()
	{
		if (!m_read_packet_header_valid)
		{
			packet_header_union header;
			m_stream.read(header.bytes);
			m_read_packet_header = big_endian_to_native(header.header);
			m_read_packet_header_valid = true;

			// Check whether this packet is valid
			if (m_read_packet_header.packet_identifier != packet_header.init.packet_identifier)
				throw new ClientProtocolException("Received unknown packet identifier");
		}

		return m_read_packet_header;
	}

	/***
	* Receives a generic packet from the client socket
	*
	* "Blocks" the calling fiber until a full packet is received, but will yield to the
	* calling fiber when no new data is available in the queue.
	*
	* Note that since this version of receive does not know the packet structure, it cannot
	* perform any endian conversion. Thus the caller must handle any endian swapping.
	*
	* NOTE: Returned data will be overwritten by future calls to receive_packet_*, so
	* caller must ensure to copy it elsewhere if they intend to keep it around.
	*/
	public const(ubyte)[] receive_packet_payload()
	{
		// First ensure that we have a valid packet header
		peek_packet_header();
		assert(m_read_packet_header_valid);
		size_t payload_length = m_read_packet_header.length - packet_header.sizeof;

		auto read_buffer = m_read_buffer[0 .. payload_length];
		m_stream.read(read_buffer);
		
		// If we have a session key already, decrypt        
		if (m_session_key_valid)
			read_buffer = decrypt(read_buffer, m_session_key);

		// Indicate that we're ready to move on to the next packet
		m_read_packet_header_valid = false;
		return read_buffer;
	}

	/***
	* Decodes a given payload into the structure(s) given by the output parameters.
	* Includes endian conversion (big endian to native).
	*
	* Throws exceptions is the packet format/sizes do not match the expected output.
	*
	* "string"-typed arguments are deserialized assuming a null-terminated C-string
	* in the payload.
	*/
	static public void decode_payload(T...)(const(ubyte)[] payload, ref T packets)
	{
		// NOTE: Ref parameters don't seem to work with variadic template foreach's right now,
		// so we just copy the result out at the bottom of the loop.
		foreach (i, p; packets)
		{
			alias typeof(p) p_type;

			static if (is(p_type : string))
			{
				// Handle strings. Myth tends to serialize these as null-terminated Mac Roman c-strings.
				size_t input_length;
				p = mac_roman_to_string(payload, input_length);
				payload = payload[input_length + 1 .. $];
			}
			else static if (isArray!p_type)
			{
				// Handle densly-packed array parameters
				static if (isDynamicArray!p_type)
				{
					alias typeof(p[0]) e_type;
					size_t elements = payload.length / e_type.sizeof;
					if (elements * e_type.sizeof != payload.length)
						throw new ClientProtocolException("Packet \"" ~ T.stringof ~ "\" has incorrect array element type");

					// Consume the rest of the payload
					p.length = elements;
					memcpy(p.ptr, payload.ptr, payload.length);
					payload = [];
				}
				else
				{
					size_t array_bytes = p.length * p[0].sizeof;
					if (payload.length < array_bytes)
						throw new ClientProtocolException("Packet \"" ~ T.stringof ~ "\" has insufficient length");

					// Copy and trim off what we just consumed
					memcpy(p.ptr, payload.ptr, array_bytes);
					payload = payload[array_bytes .. $];
				}
			}
			else
			{
				if (payload.length < p.sizeof)
					throw new ClientProtocolException("Packet \"" ~ T.stringof ~ "\" has insufficient length");

				// Copy and trim off what we just consumed
				memcpy(&p, payload.ptr, p.sizeof);
				payload = payload[p.sizeof .. $];
			}

			// Copy back to the output parameter
			packets[i] = big_endian_to_native(p);
		}

		// If there's anything left, we've messed up the structure somewhere...
		if (payload.length)
			throw new ClientProtocolException("Packet \"" ~ T.stringof ~ "\" has excessive length");
	}

	/***
	* Receives a specific (typed) packet from the client socket
	*
	* If a packet is received but it does not match the given packet type,
	* an exception will be thrown and the packet payload will remain in the queue. Thus
	* it is safe for a caller to catch the exception and proceed if a certain packet type
	* is "optional".
	*
	* If the packet type matches but the structure does not (mismatched sizes), the packet
	* will be removed from the queue and an exception will be thrown. This is typically a
	* critical error.
	*/
	public void receive_packet(T...)(packet_type type, ref T packets)
	{
		packet_header header = peek_packet_header();
		if (type != header.type)
			throw new UnexpectedPacketTypeException("Received unexpected packet type " ~ to!string(header.type));

		decode_payload(receive_packet_payload(), packets);
	}

	/***
	* Convenience alternative syntax of receive_packet when there's only a single structure to receive
	*/
	public T receive_packet_typed(T)(packet_type type)
	{
		T packet;
		receive_packet(type, packet);
		return packet;
	}

	/***
	* Encodes a given payload structure
	* Includes endian conversion (native to big endian).
	*
	* "string"-typed arguments are serialized by appending a null-terminated C-string.
	*/
	static public immutable(ubyte)[] encode_payload(T...)(ref T packets)
	{
		ubyte[] payload;

		foreach (p; packets)
		{
			alias typeof(p) p_type;
			p = native_to_big_endian(p);
			size_t write_index = payload.length;

			static if (is(p_type : string))
			{
				payload ~= string_to_mac_roman(p);
			}
			else static if (isArray!p_type)
			{
				// Handle densly-packed array parameters
				// NOTE: This will still trigger for static arrays even though the else
				// path works fine for them, but either should be equivalent in that case.
				size_t array_bytes = p.length * p[0].sizeof;
				payload.length += array_bytes;
				memcpy(payload.ptr + write_index, p.ptr, array_bytes);
			}
			else
			{
				payload.length += p.sizeof;
				memcpy(payload.ptr + write_index, &p, p.sizeof);
			}
		}

		return assumeUnique(payload);
	}

	/***
	* Send packet with the given payload already prepared
	*/
	public void send_packet_payload(packet_type type, immutable(ubyte)[] payload)
	{
		// Decent chunk of stack space, but avoids GC
		ubyte[MAXIMUM_PACKET_SIZE] encrypted_payload;

		if (m_session_key_valid)
		{
			// No GC for this part
			uint random0 = m_session_rng.front();
			m_session_rng.popFront();
			uint random1 = m_session_rng.front();
			m_session_rng.popFront();

			auto encrypted_size = payload.length + 24;

			encrypt(payload, m_session_key, random0, random1, encrypted_payload[0 .. encrypted_size]);
			payload = assumeUnique(encrypted_payload[0 .. encrypted_size]);
		}

		// Fill out header
		packet_header header = packet_header.init;

		// Make sure we haven't constructed a packet bigger than we can send...
		auto total_packet_size = header.sizeof + payload.length;
		assert(total_packet_size < MAXIMUM_PACKET_SIZE);

		header.type = type;
		header.length = cast(int)total_packet_size;
		packet_header_union send_header;
		send_header.header = native_to_big_endian(header);

		// Send header and payload
		m_stream.write(send_header.bytes);
		m_stream.write(payload);
	}

	/***
	* Send a packet with the given set of data structures.
	*/
	public void send_packet(T...)(packet_type type, T packets)
	{
		send_packet_payload(type, encode_payload(packets));
	}

	
	static public const(ubyte)[] encode_server_message_payload(server_message_type type, string message = "")
	{
		assert(message.length < 128);

		// Send appropriate message to user
		server_message_packet packet;
		packet.error_code = type;
		packet.message[0 .. message.length] = message[];
		packet.message[message.length] = 0; // Null terminator
		return encode_payload(packet);
	}

	/***
	* Convenience function that sends a server message to the user
	* NOTE: Currently assumes string is castable to simple 7-bit ascii...
	*/
	public void send_server_message(server_message_type type, string message = "")
	{
		send_packet(packet_type._server_message_packet, encode_server_message_payload(type, message));
	}

	// Bunch of delegated stuff
	@property public bool empty() { return m_stream.empty; }
	@property public bool connected() const { return m_stream.connected; }
	public void close() { if (m_stream.connected) m_stream.close(); }

	@property public pure nothrow string remote_address_string() const { return m_remote_address_string; }
	@property public pure nothrow int remote_address_ipv4() const { return m_remote_address_ipv4; }


	private TCPConnection m_stream;

	private string m_remote_address_string;
	private int m_remote_address_ipv4;

	// Keys for encryption protocol
	private encode_packets.key_type m_server_private_key;
	private encode_packets.key_type m_server_public_key;
	private encode_packets.key_type m_client_public_key;
	private encode_packets.key_type m_session_key;
	private bool m_session_key_valid;
	private Mt19937 m_session_rng;

	// Read buffer and state
	private packet_header m_read_packet_header;
	private bool m_read_packet_header_valid;
	private ubyte[MAXIMUM_PACKET_SIZE] m_read_buffer;
};
