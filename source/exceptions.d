module exceptions;

import std.exception;
import std.conv;

// Exception type for all errors in host/client protocol
public class ClientProtocolException : Exception
{
	@safe this(string msg) { super(msg); }
};

public class UnexpectedPacketTypeException : ClientProtocolException
{
	@safe this(string msg) { super(msg); }
};

public class ClientKickedException : Exception
{
	@safe this(int target_user_id, int admin_user_id, string reason = "")
	{
		string msg = "Client ID " ~ to!string(target_user_id) ~ " kicked by ID " ~ to!string(admin_user_id);
		if (reason.length > 0) msg ~= " for "~ reason ~ ".";
		super(msg);
	}
};

public class InternalException : Exception
{
	@safe this(string msg) { super(msg); }
};

public class HostProxyException : Exception
{
	@safe this(string msg) { super("HostProxy: " ~ msg); }
};

public class GoogleCloudStorageException : Exception
{
    // Because of how these exceptions (and other types) fall all the way out of the upload
    // loop, we don't prepend a specific context in here, as the site that logs the exception does
    @safe this(string msg) { super(msg); }
}


// Server messsage exceptions
// These correspond to (a subset of) the following enumeration and automatically
// send the relevant message back to the user when they are triggered.
enum server_message_type
{
	_syntax_error_msg = 0,
	_login_failed_games_not_allowed,
	_login_failed_invalid_version,
	_login_failed_bad_user_or_password,
	_user_not_logged_in_msg,
	_bad_metaserver_version_msg,
	_user_already_logged_in_msg,
	_unknown_game_type_msg,
	_login_successful_msg,
	_logout_successful_msg,
	_player_not_in_room_msg,
	_game_already_exists_msg,
	_account_already_logged_in,
	_room_full_msg,
	_metaserver_account_locked_msg,
	_metaserver_not_supported,
    _login_failed_guests_disallowed,
    _login_failed_guest_name_taken,
	NUMBER_OF_MESSAGE_TYPES
};

public class ServerMessageException : Exception
{
	@safe this(server_message_type t, string msg)
	{
		super(msg);
		type = t;
	}
	
	public server_message_type type;
};

public class TooManyClientsException : ServerMessageException
{
	@safe this()
	{
		super(server_message_type._room_full_msg,
			  "The maximum allowed number of clients are already connected");
	}
};

public class DuplicateClientException : ServerMessageException
{
	@safe this(int user_id)
	{
		super(server_message_type._user_already_logged_in_msg,
			  "Client ID " ~ to!string(user_id) ~ " is already logged in");
	}
};

public class NotLoggedInException : ServerMessageException
{
	// TODO: IP address or other info?
	@safe this()
	{
		super(server_message_type._user_not_logged_in_msg,
			  "Room client is not logged in");
	}
};

public class NotAllowedInRoomException : ServerMessageException
{
    @safe this(int user_id)
	{
        // "Not logged in" is about as closest we can get with the current error messages...
		super(server_message_type._user_not_logged_in_msg,
			  "Client ID" ~ to!string(user_id) ~ " is not allowed in room");
	}
};

public class BadUserNamePasswordException : ServerMessageException
{
	@safe this(string user_name)
	{
		super(server_message_type._login_failed_bad_user_or_password,
			  "Incorrect user name or password for user '" ~ user_name ~ "'");
	}
};

public class InvalidVersionException : ServerMessageException
{
	@safe this(string user_name, int ver, int build)
	{
		super(server_message_type._login_failed_invalid_version,
			  "Invalid version " ~ to!string(ver) ~ ", build " ~ to!string(build) ~ " for user '" ~ user_name ~ "'");
	}
};

public class InvalidGameException : ServerMessageException
{
	@safe this(string user_name)
	{
		super(server_message_type._login_failed_games_not_allowed,
			  "Invalid game for user '" ~ user_name ~ "'");
	}
};

public class BannedUserException : ServerMessageException
{
	@safe this(string user_name, string reason)
	{
		super(server_message_type._metaserver_account_locked_msg,
			  "Client '" ~ user_name ~
			  (reason.length > 0 ?  "' is banned for " ~ reason : "' is banned"));
	}
}

public class GuestsDisallowedException : ServerMessageException
{
	@safe this(string user_name)
	{
        super(server_message_type._login_failed_guests_disallowed,
			  "User '" ~ user_name ~ "' attempted to login as a guest, but guests are disabled");
	}
}

public class GuestNameTakenException : ServerMessageException
{
	@safe this(string user_name)
	{
        super(server_message_type._login_failed_guest_name_taken,
			  "Guest login not allowed as '" ~ user_name ~ "' is registered");
		
	}
}