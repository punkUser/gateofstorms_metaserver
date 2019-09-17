module log;

import std.stdio;
import std.file;
import std.datetime;
import std.string;

import vibe.data.json;

// Very simple file logging - can expand when needed

// TODO: Fix for multiple threads/shared
private	static File s_log;

public static this()
{
	s_log = stdout;
}

@safe public void initialize_logging(string file_name)
{
	s_log = File(file_name, "a");
}

@safe private string get_time_string()
{
	auto dt = Clock.currTime();
	return format("%04d-%02d-%02d %02d:%02d:%02d",
				  dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second);
}

@safe public void log_message(A...)(in char[] format, A args)
{
	s_log.writefln("%s: " ~ format, get_time_string(), args);
	s_log.flush();
}


// Read JSON config files into structures
// Doesn't necessarily fit in "log" module, but it's close enough
@safe public T read_config(T)(string config_file)
{
	T config = T.init;
	try
	{
		string contents = readText(config_file);
		log_message("Loading config from from '%s'...", config_file);
		deserializeJson(config, parseJson(contents));
	}
	catch (FileException e) {}
	catch (Exception e) { log_message("Parse error: %s", e.msg); }

	log_message("Done loading config.");
	return config;
}
