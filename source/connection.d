module connection;

import exceptions;
import myth_socket;
import log;

import std.stdio;
import vibe.core.net;

// Utility base class to automatically handle relevant exceptions per-connection,
// including returning the associated error messages to the client.
class Connection
{
    protected this() {}

    public final void run(TCPConnection stream)
    {
        // Call the derived fiber run function and catch any relevant server exceptions
        auto socket = new MythSocket(stream);

        // We handle the majority of exceptions here and don't let them "fall through"
        // to vibe's default handler. We can happily return here and have the connection closed
        // nicely, so no need to terminate fibers with exceptions as before.
        // Note that VisualD does not seem to interact well with fibers+exceptions,
        // so avoid debugging when an exception is thrown or bad stuff happens.
        try
        {
            run_internal(socket);
        }
        catch (ServerMessageException e)
        {
            socket.send_server_message(e.type, e.msg);
            log_message("Connection: %s", e.msg);
        }
        catch (Exception e)
        {
            log_message("Connection: %s", e.msg);
        }

        // If we're still connected, close it
        socket.close();
    }

    /***
    * Fiber run function to be overridden by derived classes
    */
    protected abstract void run_internal(MythSocket socket);
};
