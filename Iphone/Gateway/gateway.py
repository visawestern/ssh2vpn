#!/usr/bin/env python3
"""Personal VPN gateway. Run over an authenticated SSH exec channel.

The process speaks only framed stdin/stdout. It does not listen on a socket,
does not daemonize, and has no persistence requirement.
"""

import asyncio
import fcntl
import hashlib
import os
import struct
import subprocess
import sys
from typing import NamedTuple

VERSION = 1
HEADER = struct.Struct("!BBHQL")
MAX_PAYLOAD = 1024 * 1024
MAX_ACTIVE_FLOWS = 4096
TCP_IDLE_TIMEOUT = 300
UDP_IDLE_TIMEOUT = 60
FLOW_SWEEP_INTERVAL = 5
OPEN = 1
DATA = 2
FIN = 3
RESET = 4
CLOSE = 5
PING = 6
PONG = 7
PACKET = 8
HELLO = 9
HELLO_ACK = 10
TCP = 1
UDP = 2
TUNSETIFF = 0x400454CA
IFF_TUN = 0x0001
IFF_NO_PI = 0x1000
IFNAMSIZ = 16
BROKER_HEADER = struct.Struct("!BI")
BROKER_PACKET = 1
TUN_CIDR = "10.203.0.0/30"
TUN_ADDRESS = "10.203.0.1/30"
TUN6_CIDR = "fd00:203::/64"
TUN6_ADDRESS = "fd00:203::1/64"


class TunnelSubnet(NamedTuple):
    """Address pair that routes one broker through one VPS TUN.

    Two devices using the same VPS pick disjoint /30 and /64 ranges because
    the subnet is derived from the (per-device) broker id.
    """

    v4_gateway: str
    v4_cidr: str
    v6_gateway: str
    v6_cidr: str


LEGACY_SUBNET = TunnelSubnet(TUN_ADDRESS, TUN_CIDR, TUN6_ADDRESS, TUN6_CIDR)


def subnet_for_broker(broker_id):
    digest = hashlib.sha256(broker_id.encode("ascii")).digest()
    h1, h2 = digest[0], digest[1]
    return TunnelSubnet(
        v4_gateway=f"10.203.{h1}.{h2}.1/30",
        v4_cidr=f"10.203.{h1}.{h2}.0/30",
        v6_gateway=f"fd00:203:{h1:02x}{h2:02x}::1/64",
        v6_cidr=f"fd00:203:{h1:02x}{h2:02x}::/64",
    )
PROBE_HOST = os.environ.get("PVVPN_PROBE_HOST", "1.1.1.1")
PROBE_PORT = int(os.environ.get("PVVPN_PROBE_PORT", "443"))
PROBE_TIMEOUT = float(os.environ.get("PVVPN_PROBE_TIMEOUT", "5"))
PROBE_TARGET_OVERRIDDEN = "PVVPN_PROBE_HOST" in os.environ


def open_tun_device():
    """Open a Linux TUN device for raw IP packet mode.

    The process must be started with the VPS owner's permission to access
    /dev/net/tun. Interface/address/NAT provisioning is performed immediately
    after the first packet frame and rolled back when the session exits.
    """
    fd = os.open("/dev/net/tun", os.O_RDWR)
    ifr = struct.pack("16sH22x", b"personalvpn%d", IFF_TUN | IFF_NO_PI)
    result = fcntl.ioctl(fd, TUNSETIFF, ifr)
    name = struct.unpack("16sH22x", result)[0].split(b"\0", 1)[0].decode("ascii")
    return fd, name


def default_interface(run=subprocess.run):
    result = run(["ip", "route", "show", "default"], check=True, capture_output=True, text=True)
    tokens = result.stdout.split()
    try:
        return tokens[tokens.index("dev") + 1]
    except (ValueError, IndexError):
        raise RuntimeError("cannot determine VPS default network interface")


def _sysctl_value(run, key):
    try:
        return run(["sysctl", "-n", key], check=True, capture_output=True, text=True).stdout.strip()
    except (subprocess.CalledProcessError, OSError):
        return None


def nat_rule(tool, action, source, uplink, comment=None):
    rule = [tool, "-t", "nat", action, "POSTROUTING", "-s", source, "-o", uplink, "-j", "MASQUERADE"]
    if comment is not None:
        rule += ["-m", "comment", "--comment", comment]
    return rule


def configure_tun(name, run=subprocess.run, comment=None, subnet=None):
    """Configure forwarding/NAT for the disposable TUN.

    Returns a (uplink, saved_sysctls) pair so callers can revert forwarding
    and drop the NAT rule on shutdown. When subnet is omitted the legacy
    10.203.0.0/30 default (TUN_CIDR) is used.
    """
    subnet = subnet or LEGACY_SUBNET
    uplink = default_interface(run)
    run(["ip", "addr", "replace", subnet.v4_gateway, "dev", name], check=True)
    run(["ip", "-6", "addr", "replace", subnet.v6_gateway, "dev", name], check=True)
    run(["ip", "link", "set", "dev", name, "up"], check=True)
    saved = {
        "net.ipv4.ip_forward": _sysctl_value(run, "net.ipv4.ip_forward"),
        "net.ipv6.conf.all.forwarding": _sysctl_value(run, "net.ipv6.conf.all.forwarding"),
    }
    run(["sysctl", "-w", "net.ipv4.ip_forward=1"], check=True, capture_output=True, text=True)
    run(["sysctl", "-w", "net.ipv6.conf.all.forwarding=1"], check=True, capture_output=True, text=True)
    for tool, source in (("iptables", subnet.v4_cidr), ("ip6tables", subnet.v6_cidr)):
        if run(nat_rule(tool, "-C", source, uplink, comment), check=False).returncode != 0:
            run(nat_rule(tool, "-A", source, uplink, comment), check=True)
    return uplink, saved


def cleanup_tun(name, uplink, run=subprocess.run, comment=None, restore=None, subnet=None):
    subnet = subnet or LEGACY_SUBNET
    for tool, source in (("iptables", subnet.v4_cidr), ("ip6tables", subnet.v6_cidr)):
        run(nat_rule(tool, "-D", source, uplink, comment), check=False)
    run(["ip", "addr", "flush", "dev", name], check=False)
    run(["ip", "link", "set", "dev", name, "down"], check=False)
    if restore:
        for key, value in restore.items():
            if value is not None and value != "1":
                run(["sysctl", "-w", f"{key}={value}"], check=False, capture_output=True, text=True)


async def connectivity_probe():
    """Reachability check through the VPS's default route.

    A connected SSH channel does not prove the tunnel actually carries
    traffic. The status byte appended to HELLO_ACK lets the client distinguish
    "SSH is up" from "the VPS can reach the Internet". Falls back between the
    public IPv4 and IPv6 endpoints.
    """
    for host in (PROBE_HOST, "2606:4700:4700::1111"):
        if PROBE_TARGET_OVERRIDDEN and host != PROBE_HOST:
            continue
        try:
            reader, writer = await asyncio.wait_for(
                asyncio.open_connection(host, PROBE_PORT), PROBE_TIMEOUT
            )
            writer.close()
            try:
                await writer.wait_closed()
            except OSError:
                pass
            return 0
        except (OSError, asyncio.TimeoutError):
            continue
    return 1


class ProtocolError(Exception):
    pass


class PacketBroker:
    """Coordinates one VPS TUN across all SSH gateway processes.

    One process owns/configures the TUN. Other SSH sessions join through a
    private Unix stream socket and exchange packet records with that owner.
    This prevents three independent route/TUN instances from being created.
    """

    def __init__(self, broker_id, send_to_session):
        self.broker_id = broker_id
        self.send_to_session = send_to_session
        self.path = os.path.join("/tmp", "personalvpn-" + broker_id + ".sock")
        self.lock_path = os.path.join("/tmp", "personalvpn-" + broker_id + ".lock")
        self.subnet = subnet_for_broker(broker_id)
        self.tun_fd = None
        self.tun_name = None
        self.tun_uplink = None
        self.saved_sysctls = None
        self.server = None
        self.writer = None
        self.clients = set()
        self.client_tasks = set()
        self.local_outgoing = asyncio.Queue(maxsize=512)
        self.round_robin = 0
        self.owner = False
        self.tun_task = None
        self.closed = False
        self.rejoin_task = None
        self.rejoin_in_progress = False
        self._lockfd = None

    async def _acquire_owner_lock(self):
        """Become the sole owner via an exclusive, non-blocking flock.

        The lock — not the socket file — arbitrates ownership. This matters
        because asyncio.start_unix_server unconditionally unlinks any existing
        socket file before binding, so relying on bind() to raise EADDRINUSE would
        let two racing processes each strip the other's socket and both become
        owner (split-brain, two TUNs). The kernel lock is atomic and is released
        automatically if the owner crashes.
        """
        if self._lockfd is None:
            self._lockfd = open(self.lock_path, "w")
        try:
            fcntl.flock(self._lockfd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            return False
        return True

    def _release_owner_lock(self):
        if self._lockfd is not None:
            try:
                fcntl.flock(self._lockfd, fcntl.LOCK_UN)
                self._lockfd.close()
            except OSError:
                pass
            self._lockfd = None

    async def _try_join(self):
        try:
            self.reader, self.writer = await asyncio.wait_for(
                asyncio.open_unix_connection(self.path), timeout=1)
        except (OSError, asyncio.TimeoutError):
            return False
        task = asyncio.create_task(self.client_reader())
        self.client_tasks.add(task)
        task.add_done_callback(self.client_tasks.discard)
        return True

    async def start(self):
        if self.closed:
            raise ConnectionError("packet broker is closed")
        # 1. Join an existing owner if one is already reachable.
        if await self._try_join():
            return
        # 2. Contend for ownership. The kernel lock is the source of truth: only
        #    the holder may bind the socket and configure the TUN. A loser loops
        #    back to step 1, because the winner is (by definition) a live owner
        #    it can join as a peer.
        if not await self._acquire_owner_lock():
            for _ in range(20):
                await asyncio.sleep(0.05)
                if await self._try_join():
                    return
            if await self._try_join():
                return
            raise ConnectionError("packet broker unavailable")
        try:
            self.server = await asyncio.start_unix_server(self.accept_client, path=self.path)
            os.chmod(self.path, 0o600)
            self.owner = True
            self.reader = None
            self.writer = None
            try:
                self.tun_fd, self.tun_name = await asyncio.to_thread(open_tun_device)
                self.tun_uplink, self.saved_sysctls = await asyncio.to_thread(
                    configure_tun, self.tun_name, subprocess.run, "pvvpn-" + self.broker_id, self.subnet
                )
            except BaseException:
                self.server.close()
                await self.server.wait_closed()
                try:
                    os.unlink(self.path)
                except FileNotFoundError:
                    pass
                raise
        except BaseException:
            self._release_owner_lock()
            raise
        self.tun_task = asyncio.create_task(self.tun_reader())

    async def accept_client(self, reader, writer):
        self.clients.add(writer)
        task = asyncio.create_task(self.client_reader(reader, writer))
        self.client_tasks.add(task)
        task.add_done_callback(self.client_tasks.discard)

    async def client_reader(self, reader=None, writer=None):
        reader = reader or self.reader
        writer = writer or self.writer
        try:
            while True:
                header = await reader.readexactly(BROKER_HEADER.size)
                kind, length = BROKER_HEADER.unpack(header)
                if kind != BROKER_PACKET or length > MAX_PAYLOAD:
                    raise ProtocolError("invalid broker frame")
                packet = await reader.readexactly(length)
                if not self.owner:
                    await self.send_to_session(packet)
                else:
                    await asyncio.to_thread(os.write, self.tun_fd, packet)
        except (asyncio.IncompleteReadError, ConnectionError, OSError, ProtocolError):
            pass
        finally:
            if writer is not None:
                self.clients.discard(writer)
                writer.close()
        if not self.owner:
            self._schedule_rejoin()

    def _schedule_rejoin(self):
        if self.rejoin_in_progress or self.owner or self.closed:
            return
        self.rejoin_in_progress = True
        self.rejoin_task = asyncio.create_task(self._rejoin_loop())

    async def _rejoin_loop(self):
        try:
            for attempt in range(10):
                if self.owner or self.closed:
                    return
                try:
                    await self.start()
                    return
                except BaseException:
                    await asyncio.sleep(0.5 * (attempt + 1))
        finally:
            self.rejoin_in_progress = False
            self.rejoin_task = None

    async def send_to_owner(self, packet):
        if self.owner:
            await asyncio.to_thread(os.write, self.tun_fd, packet)
            return
        if self.writer is None:
            raise ConnectionError("packet broker unavailable")
        self.writer.write(BROKER_HEADER.pack(BROKER_PACKET, len(packet)) + packet)
        await self.writer.drain()

    async def tun_reader(self):
        while self.tun_fd is not None:
            packet = await asyncio.to_thread(os.read, self.tun_fd, 65535)
            if not packet:
                continue
            destinations = [None] + list(self.clients)
            destination = destinations[self.round_robin % len(destinations)]
            self.round_robin += 1
            if destination is None:
                await self.send_to_session(packet)
            else:
                destination.write(BROKER_HEADER.pack(BROKER_PACKET, len(packet)) + packet)
                await destination.drain()

    async def close(self):
        self.closed = True
        if self.rejoin_task:
            self.rejoin_task.cancel()
        if self.tun_task:
            self.tun_task.cancel()
        for task in self.client_tasks:
            task.cancel()
        if self.server:
            self.server.close()
            await self.server.wait_closed()
        if self.writer:
            self.writer.close()
        for writer in list(self.clients):
            writer.close()
        if self.owner and self.tun_fd is not None:
            os.close(self.tun_fd)
            if self.tun_name and self.tun_uplink:
                await asyncio.to_thread(
                    cleanup_tun, self.tun_name, self.tun_uplink,
                    subprocess.run, "pvvpn-" + self.broker_id, self.saved_sysctls, self.subnet,
                )
        if self.owner:
            try:
                os.unlink(self.path)
            except FileNotFoundError:
                pass
        self._release_owner_lock()
        try:
            os.unlink(self.lock_path)
        except FileNotFoundError:
            pass
        self.tun_fd = None


class Gateway:
    def __init__(self, reader, writer, broker_id=None):
        self.reader = reader
        self.writer = writer
        self.output_lock = asyncio.Lock()
        self.tcp_writers = {}
        self.udp_transports = {}
        self.tasks = set()
        self.last_activity = {}
        self.packets_only = broker_id is not None
        self.broker = PacketBroker(broker_id, self.send) if broker_id else None

    async def start_packet_mode(self):
        if self.broker is not None and (self.broker.tun_fd is not None or self.broker.writer is not None):
            return
        if self.broker is None:
            raise ProtocolError("packet broker is not configured")
        await self.broker.start()

    async def tun_reader(self):
        raise ProtocolError("legacy independent TUN reader is disabled")

    async def send(self, frame_type, stream_id=0, payload=b""):
        if len(payload) > MAX_PAYLOAD:
            raise ProtocolError("payload too large")
        async with self.output_lock:
            self.writer.write(HEADER.pack(VERSION, frame_type, 0, stream_id, len(payload)) + payload)
            await self.writer.drain()

    async def read_frame(self):
        header = await self.reader.readexactly(HEADER.size)
        version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
        if version != VERSION or reserved != 0:
            raise ProtocolError("invalid frame header")
        if length > MAX_PAYLOAD:
            raise ProtocolError("payload too large")
        payload = await self.reader.readexactly(length)
        return frame_type, stream_id, payload

    async def tcp_reader(self, stream_id, reader):
        try:
            while data := await reader.read(64 * 1024):
                await self.send(DATA, stream_id, data)
            await self.send(FIN, stream_id)
        except (ConnectionError, asyncio.IncompleteReadError, ProtocolError):
            await self.send(RESET, stream_id)

    async def open_tcp(self, stream_id, destination):
        reader, writer = await asyncio.wait_for(asyncio.open_connection(destination[0], destination[1]), timeout=10)
        self.tcp_writers[stream_id] = writer
        self.last_activity[stream_id] = asyncio.get_running_loop().time()
        task = asyncio.create_task(self.tcp_reader(stream_id, reader))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def open_udp(self, stream_id, destination):
        queue = asyncio.Queue()

        class Datagram(asyncio.DatagramProtocol):
            def datagram_received(_, data, _address):
                queue.put_nowait(data)

            def error_received(_, _exception):
                queue.put_nowait(None)

        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(Datagram, remote_addr=destination)
        self.udp_transports[stream_id] = (transport, queue)
        self.last_activity[stream_id] = asyncio.get_running_loop().time()
        task = asyncio.create_task(self.udp_reader(stream_id, queue))
        self.tasks.add(task)
        task.add_done_callback(self.tasks.discard)

    async def udp_reader(self, stream_id, queue):
        try:
            while True:
                data = await queue.get()
                if data is None:
                    break
                self.last_activity[stream_id] = asyncio.get_running_loop().time()
                await self.send(DATA, stream_id, data)
        finally:
            await self.send(CLOSE, stream_id)

    async def close_flow(self, stream_id):
        self.last_activity.pop(stream_id, None)
        writer = self.tcp_writers.pop(stream_id, None)
        if writer is not None:
            writer.close()
            await writer.wait_closed()
        udp = self.udp_transports.pop(stream_id, None)
        if udp is not None:
            udp[0].close()

    async def expire_idle_flows(self):
        while True:
            await asyncio.sleep(FLOW_SWEEP_INTERVAL)
            now = asyncio.get_running_loop().time()
            expired = []
            for stream_id, last in list(self.last_activity.items()):
                timeout = UDP_IDLE_TIMEOUT if stream_id in self.udp_transports else TCP_IDLE_TIMEOUT
                if now - last >= timeout:
                    expired.append(stream_id)
            for stream_id in expired:
                await self.close_flow(stream_id)
                await self.send(CLOSE, stream_id)

    async def run(self):
        sweeper = asyncio.create_task(self.expire_idle_flows())
        self.tasks.add(sweeper)
        try:
            while True:
                frame_type, stream_id, payload = await self.read_frame()
                if self.packets_only and frame_type in (OPEN, DATA, FIN):
                    raise ProtocolError("flow frames are not accepted in packet mode")
                if frame_type == OPEN:
                    if stream_id == 0 or stream_id in self.tcp_writers or stream_id in self.udp_transports:
                        await self.send(RESET, stream_id)
                        continue
                    if len(self.tcp_writers) + len(self.udp_transports) >= MAX_ACTIVE_FLOWS:
                        await self.send(RESET, stream_id)
                        continue
                    if len(payload) < 5:
                        raise ProtocolError("invalid OPEN")
                    protocol, host_len = payload[0], struct.unpack("!H", payload[1:3])[0]
                    if host_len == 0 or host_len > 255 or len(payload) != host_len + 5:
                        raise ProtocolError("invalid OPEN length")
                    host = payload[3:3 + host_len].decode("utf-8")
                    port = struct.unpack("!H", payload[3 + host_len:5 + host_len])[0]
                    if not host or not port or protocol not in (TCP, UDP):
                        raise ProtocolError("invalid OPEN destination")
                    if protocol == TCP:
                        await self.open_tcp(stream_id, (host, port))
                    else:
                        await self.open_udp(stream_id, (host, port))
                elif frame_type == DATA:
                    if stream_id in self.tcp_writers:
                        self.last_activity[stream_id] = asyncio.get_running_loop().time()
                        self.tcp_writers[stream_id].write(payload)
                        await self.tcp_writers[stream_id].drain()
                    elif stream_id in self.udp_transports:
                        self.last_activity[stream_id] = asyncio.get_running_loop().time()
                        self.udp_transports[stream_id][0].sendto(payload)
                    else:
                        await self.send(RESET, stream_id)
                elif frame_type == FIN:
                    writer = self.tcp_writers.get(stream_id)
                    if writer is not None:
                        self.last_activity[stream_id] = asyncio.get_running_loop().time()
                        writer.write_eof()
                    else:
                        await self.send(RESET, stream_id)
                elif frame_type in (CLOSE, RESET):
                    await self.close_flow(stream_id)
                elif frame_type == PING:
                    await self.send(PONG, stream_id, payload)
                elif frame_type == HELLO:
                    if stream_id != 0 or len(payload) != 16:
                        raise ProtocolError("invalid HELLO")
                    if self.broker is not None:
                        # Establish TUN ownership and broker membership before
                        # acknowledging readiness. A connected SSH channel is
                        # not sufficient if the VPS cannot provision routing.
                        await self.start_packet_mode()
                    probe = await connectivity_probe()
                    await self.send(HELLO_ACK, 0, payload + bytes([probe]))
                elif frame_type == PACKET:
                    if stream_id != 0:
                        raise ProtocolError("packet frame must use stream zero")
                    await self.start_packet_mode()
                    await self.broker.send_to_owner(payload)
                else:
                    raise ProtocolError("unknown frame")
        except (asyncio.IncompleteReadError, ConnectionError, ProtocolError):
            pass
        finally:
            sweeper.cancel()
            for stream_id in list(self.tcp_writers) + list(self.udp_transports):
                await self.close_flow(stream_id)
            for task in self.tasks:
                task.cancel()
            if self.broker is not None:
                await self.broker.close()


async def main():
    # SSH exec supplies stdin/stdout. asyncio's standard streams are enough
    # because SSH provides the encrypted byte transport around this process.
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    await loop.connect_read_pipe(lambda: asyncio.StreamReaderProtocol(reader), sys.stdin.buffer)
    writer_transport, writer_protocol = await loop.connect_write_pipe(asyncio.streams.FlowControlMixin, sys.stdout.buffer)
    writer = asyncio.StreamWriter(writer_transport, writer_protocol, reader, loop)
    broker_id = None
    if "--broker-id" in sys.argv:
        index = sys.argv.index("--broker-id")
        if index + 1 >= len(sys.argv) or not sys.argv[index + 1].isalnum() or len(sys.argv[index + 1]) > 64:
            raise SystemExit("invalid broker id")
        broker_id = sys.argv[index + 1]
    await Gateway(reader, writer, broker_id=broker_id).run()
    writer.close()


if __name__ == "__main__":
    asyncio.run(main())
