module host_proxy;

import log;
import exceptions;
import room_connection;
import myth_socket;
import room_server;

import vibe.vibe;


private class HostProxyPort
{
    // Uses 2 ports currently
	public this(HostProxy host_proxy, ushort first_port)
    {
        m_host_proxy = host_proxy;
        m_client_port = cast(ushort)first_port;
        m_host_port = cast(ushort)(first_port + 1);

        // Start listening
        listenTCP(m_client_port, &handle_client_connection, "0.0.0.0", TCPListenOptions.disableAutoClose);
        listenTCP(m_host_port,   &handle_host_connection,   "0.0.0.0", TCPListenOptions.disableAutoClose);
    }

    // Destructor, cleanup, etc. Currently these all just live until the server dies so not important.

    private void handle_client_connection(TCPConnection client_stream)
    {        
        scope(failure) client_stream.close();

        if (!m_assigned)
            throw new HostProxyException("Client connected to unassigned port " ~ to!string(client_stream.localAddress.port));
        log_message("HostProxy: Client connected to port %s", m_client_port);
        scope(exit) log_message("HostProxy: Client disconnected from port %s", m_client_port);
        
        // Find host connection in room
        auto host_connection = m_host_proxy.room_server.find_client_in_room(m_host_user_id);
        if (host_connection.isNull())
        {
            // Something went wrong... client is no longer in room but we still have a host proxy assigned!
            // Best we can do is bail for now... TBD if we ever hit this in practice and should try and forcefully
            // trigger a release here or similar.
            throw new HostProxyException("Host ID %s not found in rooms!" ~ to!string(m_host_user_id));
        }

        // Enqueue waiting client
        ++m_pending_clients.length;
        m_pending_clients[$-1] = client_stream;
        log_message("HostProxy: Pushing client for port %s (%s waiting)", m_host_port, m_pending_clients.length);

        // Signal host to connect to us for pairing with the new client connection
        m_host_proxy.send_proxy_join_packet(host_connection, m_host_port);
    }

    private void handle_host_connection(TCPConnection host_stream)
    {
        scope(failure) host_stream.close();

        if (!m_assigned)
            throw new HostProxyException("Host connected to unassigned port " ~ to!string(host_stream.localAddress.port));
        log_message("HostProxy: Host connected to port %s", m_host_port);
        scope(exit) log_message("HostProxy: Host disconnected from port %s", m_client_port);

        // Pop waiting client
        if (m_pending_clients.empty)
        {
            // Should not happen unless something went wrong in the client... treat as an error and drop this connection
            throw new HostProxyException("Host connected but no clients waiting!");
        }

        assert(m_pending_clients.length > 0);   // Should only exit here by exception otherwise
        auto client_stream = m_pending_clients[$-1];
        --m_pending_clients.length;
        log_message("HostProxy: Popped client for port %s (%s still waiting)", m_host_port, m_pending_clients.length);

        // Start the magic
        proxy_connections(host_stream, client_stream);
    }

    private static void proxy_connections(TCPConnection host_stream, TCPConnection client_stream)
    {
        log_message("HostProxy: Proxying two connections %s <-> %s", host_stream.peerAddress, client_stream.peerAddress);
        scope(exit)
        {
            log_message("HostProxy: Done proxying  %s <-> %s", host_stream.peerAddress, client_stream.peerAddress);
            host_stream.close();
            client_stream.close();
        }

        if (!host_stream.connected || !client_stream.connected)
            return;

        host_stream.tcpNoDelay = true;
        client_stream.tcpNoDelay = true;

        auto host_writer_task = Task.getThis();

        auto client_writer_task = runTask((TCPConnection host_stream, TCPConnection client_stream) {
            bool interrupt_host = true;
            try
            {
                pipeRealtime(client_stream, host_stream);
            }
            catch (InterruptException e) { interrupt_host = false; }
            catch (Exception e)
            {
                log_message("HostProxy: Client writer %s -> %s exception: %s",
                            host_stream.peerAddress, client_stream.peerAddress, e.msg);
            }

            if (interrupt_host)
                host_writer_task.interrupt();
        }, host_stream, client_stream);

        {
            bool interrupt_client = true;
            try
            {
                pipeRealtime(host_stream, client_stream);
            }
            catch (InterruptException) { interrupt_client = false; }
            catch (Exception e)
            {
                log_message("HostProxy: Host writer %s <- %s exception: %s",
                            host_stream.peerAddress, client_stream.peerAddress, e.msg);
            }

            if (interrupt_client && client_writer_task.running)
            {
                client_writer_task.interrupt();
                client_writer_task.join();
            }
        }
    }

    public bool acquire(int host_user_id)
    {
        if (m_assigned) return false;

        m_assigned = true;
        m_host_user_id = host_user_id;

        m_pending_clients = new TCPConnection[0];
        m_pending_clients.reserve(10);

        log_message("HostProxy: Acquired proxy for host ID %s, host port %s, client port %s",
                    m_host_user_id, m_host_port, m_client_port);
        return true;
    }

    // Only release if host ID matches and we are assigned
    public bool release(int host_user_id)
    {
        if (!m_assigned || (m_host_user_id != host_user_id))
            return false;

        // Just in case, clear out any pending clients
        foreach (ref c; m_pending_clients)
        {
            c.close();
        }
        m_pending_clients = null;

        log_message("HostProxy: Released proxy for host ID %s, host port %s, client port %s",
                    m_host_user_id, m_host_port, m_client_port);

        m_assigned = false;
        return true;
    }

    public @property pure nothrow ushort client_port() const { return m_client_port; }
    
    private HostProxy m_host_proxy;
    private immutable ushort m_client_port; // Port that clients connect to
	private immutable ushort m_host_port;   // Port that host connects to when a client is waiting

    // When assigned this data is valid
    private bool m_assigned = false;
	private int m_host_user_id;
    private TCPConnection[] m_pending_clients;
}


public struct HostProxyInfo
{
	// This is the address/port that clients should join to connect to the proxied game
	// Zeroed is effectively a null state
	uint address_ipv4 = 0;
	ushort port = 0;
};


public class HostProxy
{
public:
	this(RoomServer room_server, ushort port_pool_start, ushort port_pool_count)
	{
        m_room_server = room_server;

		// Set up free port pool - allocated in pairs
        // NOTE: If there becomes a need to randomize ports or similar we can make this more complex
		m_ports = new HostProxyPort[port_pool_count >> 1];
        m_port_pool_start = port_pool_start;
        foreach (i, ref p; m_ports) {
            p = new HostProxyPort(this, cast(ushort)(m_port_pool_start + 2*i));
        }
	}

	public HostProxyInfo acquire(int host_user_id)
	{
		foreach (ref p; m_ports) 
		{
			if (p.acquire(host_user_id))
            {
                HostProxyInfo info;
                info.address_ipv4 = m_room_server.address_ipv4;
                info.port = p.client_port;
                return info;
            }
		}

		// Badness, ran out of ports!
		throw new HostProxyException("No ports available for host proxy!");
	}

	public void release(int host_user_id)
	{
		foreach (ref p; m_ports)
		{
			if (p.release(host_user_id))
			{
				// There should technically be only one port per host_user_id so we could break
                // here, but we'll keep it robust against glitches for the moment.
			}
		}
	}

	public void send_proxy_join_packet(RoomConnection connection, ushort host_port) const
	{
		struct proxy_client_join_packet
		{
			ushort port;
			char[48] host;
			char[16] auth_token;
		}

		// For now we only use the ipv4 address
		proxy_client_join_packet packet;
		packet.port = host_port;
		//packet.auth_token = // TODO

		// Copy string and null terminate
		// Note that we shouldn't have any unicode chars or other wackiness in this proxy address -
		// it should be a pure IP string by this point
        auto address_string_ipv4 = m_room_server.address_string_ipv4;
		assert(address_string_ipv4.length + 1 < packet.host.sizeof);
		packet.host[0 .. address_string_ipv4.length] = address_string_ipv4[];
		packet.host[address_string_ipv4.length] = 0;

		log_message("HostProxy: Telling client ID %s to join %s:%s", connection.client.user_id, address_string_ipv4, packet.port);
		connection.send_packet(packet_type._proxy_client_join_packet, packet);
	}

    @property public pure nothrow room_server() { return m_room_server; }

private:
    RoomServer m_room_server;

	private HostProxyPort[] m_ports;
    private ushort m_port_pool_start;
}
