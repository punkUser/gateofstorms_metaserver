module main;

import login_server;
import www_server;
import myth_patch_file;
import log;
import metaserver_config;

import std.stdio;
import std.file;
import std.getopt;
import std.datetime.stopwatch : StopWatch, AutoStart;

import core.memory;

import vibe.vibe;

LoginServer run_metaserver(string config_file = "metaserver_config.json")
{
    auto config = read_config!MetaserverConfig(config_file);

    log_message("*******************************************************************************");
    log_message("Metaserver starting with config:");
    log_message(serializeToJson(config).toPrettyString());
    log_message("*******************************************************************************");

    return new LoginServer(config);
}

WWWServer run_www_server(string config_file = "www_config.json")
{
    auto config = read_config!WWWConfig(config_file);	

    log_message("*******************************************************************************");
    log_message("WWW server starting with config:");
    log_message(serializeToJson(config).toPrettyString());
    log_message("*******************************************************************************");

    return new WWWServer(config);
}


void run_gc_cleanup()
{
    runTask({
        scope(exit) log_message("Process: ERROR, GC cleanup task exited!");

        for (;;)
        {
            sleep(5.minutes);

            log_message("Process: Starting GC collect...");            
            auto sw = StopWatch(AutoStart.yes);

            GC.collect();
            GC.minimize();

            log_message("Process: Finished GC collect in %d ms. Used/free (MB): %s/%s",
						sw.peek.total!"msecs",
						GC.stats.usedSize / 1000000, GC.stats.freeSize / 1000000);
        }
    });
}

void start_servers(string[] args)
{
    try
    {
        // Command line options
        bool start_metaserver = false;
        bool start_www_server = false;     
        string log_file = "";
        auto helpInformation = getopt(args,
                                      "meta",  &start_metaserver,
                                      "www",   &start_www_server,
                                      "log",   &log_file);

        if (!log_file.empty)
            initialize_logging(log_file);

        // Good default for now if they don't specify any options
        if (!start_metaserver && !start_www_server) {
            start_metaserver = true;
        }

        LoginServer metaserver;
        WWWServer www_server;

        if (start_metaserver) metaserver   = run_metaserver();
        if (start_www_server) www_server   = run_www_server();

        run_gc_cleanup();

        // Start vibe loop
        runEventLoop();
    }
    catch (Exception e)
    {
        log_message(e.msg);
    }
}

int main(string[] args)
{
    // Get useful stack dumps on linux
    {
        import etc.linux.memoryerror;
        static if (is(typeof(registerMemoryErrorHandler)))
            registerMemoryErrorHandler();
    }

    //vibe.core.log.setLogFile("vibe_log.txt", LogLevel.Trace);
    //setLogLevel(LogLevel.debugV);

    start_servers(args);

    return 0;
}
