// NOTE: This whole "daemon" is very minimal/hacked and not meant to be a feature-complete and fully robust
// solution. It is meant to provide the minimal amount of functionality for running the myth_metaserver
// as a daemon-like process on Linux and redirecting stdout/err appropriately.

import std.stdio;
import std.file;
import std.process;
import std.file;
import std.path;

import core.stdc.stdlib;
import core.sys.posix.signal;
import core.sys.posix.unistd;
import core.sys.posix.sys.stat;

int main(string[] args)
{
    // Get useful stack dumps on linux
    {
        import etc.linux.memoryerror;
        static if (is(typeof(registerMemoryErrorHandler)))
            registerMemoryErrorHandler();
    }

    // Exe name to launch is derived from our name, stripping "_daemon" off the end if present
    // Note that linux norms are more to just have "d" on the end but we want this to work with
    // the default generated DUB executables as well.
    string child_executable = baseName(stripExtension(args[0]), "_daemon");
    
    string log_file = child_executable ~ ".log";
    string[] child_args = ["./" ~ child_executable] ~ args[1..$];

    // Daemonize under Linux:
    version (linux)
    {
        writeln("Daemonizing...");

    	auto pid = fork();
    	if (pid < 0)
            exit(EXIT_FAILURE);
    	if (pid > 0)
            exit(EXIT_SUCCESS);
        
        writefln("Successfully daemonized as pid %s.", thisProcessID);

        // Now in child process
    	umask(0);

        auto sid = setsid();
        if(sid < 0) exit(EXIT_FAILURE);
    }

    File input;
    version (linux)   input = File("/dev/null", "r");
    version (windows) input = File("nul");

    writefln("Opening %s...", log_file);
    auto output = File(log_file, "a");

    writefln("Spawning process %s...", child_executable);
    auto child = spawnProcess(child_args, input, output, output);
    writefln("Successfully started %s, pid %s.", child_executable, child.processID);

    version (linux)
    {
        // Close stdin, stdout and stderr
        // TODO: This is probably handled by some of the new flags in spawnProcess... investigate
        close(STDIN_FILENO);
        close(STDOUT_FILENO);
        close(STDERR_FILENO);
    }

    // TODO: Auto-restart loop
    wait(child);

    return 0;
}
