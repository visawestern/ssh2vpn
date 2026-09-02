import asyncio
import socket
import os
import struct
import sys
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

from Gateway import gateway

HEADER = struct.Struct("!BBHQL")
OPEN, DATA, FIN, CLOSE, HELLO, HELLO_ACK = 1, 2, 3, 5, 9, 10
TCP = 1


class GatewayIntegrationTests(unittest.IsolatedAsyncioTestCase):
    async def test_hello_nonce_is_echoed_only_as_hello_ack(self):
        async def sink(reader, writer):
            try:
                await reader.read(1)
            finally:
                writer.close()

        server = await asyncio.start_server(sink, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        env = dict(os.environ)
        env.update(PVVPN_PROBE_HOST="127.0.0.1", PVVPN_PROBE_PORT=str(port), PVVPN_PROBE_TIMEOUT="1")
        gateway_process = await asyncio.create_subprocess_exec(
            sys.executable,
            str(Path(__file__).with_name("gateway.py")),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            env=env,
        )
        nonce = bytes(range(16))
        try:
            gateway_process.stdin.write(HEADER.pack(1, HELLO, 0, 0, len(nonce)) + nonce)
            await gateway_process.stdin.drain()
            header = await asyncio.wait_for(gateway_process.stdout.readexactly(HEADER.size), 2)
            version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
            payload = await gateway_process.stdout.readexactly(length)
            self.assertEqual((version, frame_type, reserved, stream_id, len(payload)), (1, HELLO_ACK, 0, 0, 17))
            self.assertEqual(payload[:16], nonce)
            self.assertEqual(payload[16:], b"\x00")
        finally:
            gateway_process.stdin.close()
            await gateway_process.wait()
            server.close()
            await server.wait_closed()

    def test_tun_bootstrap_is_reversible_and_uses_default_uplink(self):
        calls = []

        def run(args, **kwargs):
            calls.append((args, kwargs))
            result = Mock(returncode=0, stdout="default via 192.0.2.1 dev eth0\n")
            if args[0] == "iptables" and args[3] == "-C":
                result.returncode = 1
            if args[0] == "sysctl" and args[1] == "-n":
                result.stdout = "0"
            return result

        uplink, saved = gateway.configure_tun("personalvpn0", run=run)
        self.assertEqual(uplink, "eth0")
        self.assertEqual(saved["net.ipv4.ip_forward"], "0")
        self.assertIn(["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", gateway.TUN_CIDR, "-o", "eth0", "-j", "MASQUERADE"], [call[0] for call in calls])
        gateway.cleanup_tun("personalvpn0", "eth0", run=run, restore=saved)
        self.assertIn(["iptables", "-t", "nat", "-D", "POSTROUTING", "-s", gateway.TUN_CIDR, "-o", "eth0", "-j", "MASQUERADE"], [call[0] for call in calls])
        self.assertIn(["sysctl", "-w", "net.ipv4.ip_forward=0"], [call[0] for call in calls])

    async def test_tcp_round_trip_over_stdin_stdout(self):
        async def echo(reader, writer):
            while data := await reader.read(65536):
                writer.write(data)
                await writer.drain()
            writer.close()

        server = await asyncio.start_server(echo, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        gateway = await asyncio.create_subprocess_exec(
            sys.executable,
            str(Path(__file__).with_name("gateway.py")),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
        )
        try:
            host = b"127.0.0.1"
            open_payload = bytes([TCP]) + struct.pack("!H", len(host)) + host + struct.pack("!H", port)
            gateway.stdin.write(HEADER.pack(1, OPEN, 0, 41, len(open_payload)) + open_payload)
            gateway.stdin.write(HEADER.pack(1, DATA, 0, 41, 5) + b"hello")
            await gateway.stdin.drain()
            header = await asyncio.wait_for(gateway.stdout.readexactly(HEADER.size), 2)
            version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
            payload = await gateway.stdout.readexactly(length)
            self.assertEqual((version, frame_type, reserved, stream_id, payload), (1, DATA, 0, 41, b"hello"))
        finally:
            gateway.stdin.close()
            await gateway.wait()
            server.close()
            await server.wait_closed()

    async def test_tcp_fin_is_half_close_and_remote_eof_is_forwarded(self):
        async def half_close_echo(reader, writer):
            data = await reader.read(65536)
            await reader.read()
            writer.write(data)
            await writer.drain()
            writer.close()

        server = await asyncio.start_server(half_close_echo, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        process = await asyncio.create_subprocess_exec(
            sys.executable, str(Path(__file__).with_name("gateway.py")),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        )
        try:
            host = b"127.0.0.1"
            open_payload = bytes([TCP]) + struct.pack("!H", len(host)) + host + struct.pack("!H", port)
            process.stdin.write(HEADER.pack(1, OPEN, 0, 42, len(open_payload)) + open_payload)
            process.stdin.write(HEADER.pack(1, DATA, 0, 42, 5) + b"hello")
            process.stdin.write(HEADER.pack(1, FIN, 0, 42, 0))
            await process.stdin.drain()
            frames = []
            for _ in range(2):
                header = await asyncio.wait_for(process.stdout.readexactly(HEADER.size), 2)
                version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
                payload = await process.stdout.readexactly(length)
                frames.append((version, frame_type, reserved, stream_id, payload))
            self.assertEqual(frames[0], (1, DATA, 0, 42, b"hello"))
            self.assertEqual(frames[1], (1, FIN, 0, 42, b""))
        finally:
            process.stdin.close()
            await process.wait()
            server.close()
            await server.wait_closed()

    async def test_udp_round_trip_over_stdin_stdout(self):
        class Echo(asyncio.DatagramProtocol):
            def connection_made(self, transport):
                self.transport = transport

            def datagram_received(self, data, address):
                self.transport.sendto(data, address)

        loop = asyncio.get_running_loop()
        transport, _ = await loop.create_datagram_endpoint(Echo, local_addr=("127.0.0.1", 0))
        port = transport.get_extra_info("sockname")[1]
        gateway = await asyncio.create_subprocess_exec(
            sys.executable,
            str(Path(__file__).with_name("gateway.py")),
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
        )
        try:
            host = b"127.0.0.1"
            open_payload = bytes([2]) + struct.pack("!H", len(host)) + host + struct.pack("!H", port)
            gateway.stdin.write(HEADER.pack(1, OPEN, 0, 77, len(open_payload)) + open_payload)
            gateway.stdin.write(HEADER.pack(1, DATA, 0, 77, 3) + b"udp")
            await gateway.stdin.drain()
            header = await asyncio.wait_for(gateway.stdout.readexactly(HEADER.size), 2)
            version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
            payload = await gateway.stdout.readexactly(length)
            self.assertEqual((version, frame_type, reserved, stream_id, payload), (1, DATA, 0, 77, b"udp"))
        finally:
            gateway.stdin.close()
            await gateway.wait()
            transport.close()

    async def test_malformed_hello_is_rejected_without_ack(self):
        process = await asyncio.create_subprocess_exec(
            sys.executable, str(Path(__file__).with_name("gateway.py")),
            stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        )
        try:
            process.stdin.write(HEADER.pack(1, HELLO, 0, 0, 15) + bytes(15))
            await process.stdin.drain()
            await asyncio.wait_for(process.wait(), 2)
            self.assertEqual(await process.stdout.read(), b"")
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def test_idle_flow_expiration_emits_close(self):
        class Writer:
            def __init__(self):
                self.bytes = bytearray()

            def write(self, value):
                self.bytes.extend(value)

            async def drain(self):
                return None

        class DatagramTransport:
            def close(self):
                return None

        old_interval = gateway_module_interval = gateway.FLOW_SWEEP_INTERVAL
        old_udp_timeout = gateway.UDP_IDLE_TIMEOUT
        gateway.FLOW_SWEEP_INTERVAL = 0.01
        gateway.UDP_IDLE_TIMEOUT = 0
        writer = Writer()
        instance = gateway.Gateway(None, writer)
        instance.udp_transports[9] = (DatagramTransport(), asyncio.Queue())
        instance.last_activity[9] = 0
        task = asyncio.create_task(instance.expire_idle_flows())
        try:
            await asyncio.sleep(0.03)
            self.assertNotIn(9, instance.udp_transports)
            self.assertEqual(HEADER.unpack(bytes(writer.bytes[:HEADER.size]))[:4], (1, CLOSE, 0, 9))
        finally:
            task.cancel()
            gateway.FLOW_SWEEP_INTERVAL = old_interval
            gateway.UDP_IDLE_TIMEOUT = old_udp_timeout

    async def test_packet_broker_has_one_tun_owner_and_accepts_peer_packets(self):
        sent_to_session = []

        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        async def owner_output(packet):
            sent_to_session.append((0, packet))

        async def peer_output(packet):
            sent_to_session.append((1, packet))

        def record_write(fd, packet):
            sent_to_session.append((fd, packet))
            return len(packet)

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", return_value=("eth0", {})), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "write", side_effect=record_write), \
             patch.object(gateway.os, "close"):
            owner = gateway.PacketBroker("testbroker", owner_output)
            await owner.start()
            peer = gateway.PacketBroker("testbroker", peer_output)
            await peer.start()
            try:
                await asyncio.sleep(0.02)
                self.assertTrue(owner.owner)
                self.assertFalse(peer.owner)
                await peer.send_to_owner(b"packet")
                await asyncio.sleep(0.02)
                self.assertIn((99, b"packet"), sent_to_session)
            finally:
                await peer.close()
                await owner.close()




def launch(*args, **env_overrides):
    env = dict(os.environ)
    env.update(env_overrides)
    return asyncio.create_subprocess_exec(
        sys.executable,
        str(Path(__file__).with_name("gateway.py")),
        *args,
        stdin=asyncio.subprocess.PIPE,
        stdout=asyncio.subprocess.PIPE,
        env=env,
    )


async def read_frame(stream, timeout=2):
    header = await asyncio.wait_for(stream.readexactly(HEADER.size), timeout)
    version, frame_type, reserved, stream_id, length = HEADER.unpack(header)
    payload = await asyncio.wait_for(stream.readexactly(length), timeout)
    return frame_type, stream_id, payload


def free_tcp_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class Round1ArchitectureTests(unittest.IsolatedAsyncioTestCase):
    async def test_hello_ack_carries_connectivity_probe_status_ok(self):
        async def sink(reader, writer):
            try:
                await reader.read(1)
            finally:
                writer.close()

        server = await asyncio.start_server(sink, "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        nonce = bytes(range(16))
        process = await launch(
            PVVPN_PROBE_HOST="127.0.0.1",
            PVVPN_PROBE_PORT=str(port),
            PVVPN_PROBE_TIMEOUT="1",
        )
        try:
            process.stdin.write(HEADER.pack(1, HELLO, 0, 0, len(nonce)) + nonce)
            await process.stdin.drain()
            frame_type, stream_id, payload = await read_frame(process.stdout)
            self.assertEqual((frame_type, stream_id), (HELLO_ACK, 0))
            self.assertEqual(payload[:16], nonce)
            self.assertEqual(payload[16:], b"\x00")
        finally:
            process.stdin.close()
            await process.wait()
            server.close()
            await server.wait_closed()

    async def test_hello_ack_reports_probe_failure(self):
        closed = free_tcp_port()
        nonce = bytes(range(16))
        process = await launch(
            PVVPN_PROBE_HOST="127.0.0.1",
            PVVPN_PROBE_PORT=str(closed),
            PVVPN_PROBE_TIMEOUT="0.5",
        )
        try:
            process.stdin.write(HEADER.pack(1, HELLO, 0, 0, len(nonce)) + nonce)
            await process.stdin.drain()
            frame_type, stream_id, payload = await read_frame(process.stdout)
            self.assertEqual((frame_type, stream_id), (HELLO_ACK, 0))
            self.assertEqual(payload[:16], nonce)
            self.assertEqual(payload[16:], b"\x01")
        finally:
            process.stdin.close()
            await process.wait()

    async def test_packet_mode_rejects_flow_open_and_kills_session(self):
        process = await launch("--broker-id", "probe1")
        try:
            host = b"127.0.0.1"
            payload = bytes([TCP]) + struct.pack("!H", len(host)) + host + struct.pack("!H", 9)
            process.stdin.write(HEADER.pack(1, OPEN, 0, 41, len(payload)) + payload)
            await process.stdin.drain()
            await asyncio.wait_for(process.wait(), 2)
            self.assertEqual(await process.stdout.read(), b"")
        finally:
            if process.returncode is None:
                process.kill()
                await process.wait()

    async def test_tun_bootstrap_reverts_sysctl_and_tags_nat_rules(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            result = Mock(returncode=0, stdout="")
            if args[:2] == ["ip", "route"]:
                result.stdout = "default via 192.0.2.1 dev eth0\n"
            if args[0] in ("iptables", "ip6tables") and args[3] == "-C":
                result.returncode = 1
            if args[0] == "sysctl" and args[1] == "-n":
                result.stdout = "0"
            return result

        uplink, saved = gateway.configure_tun("personalvpn0", run=run, comment="pvvpn-setup")
        self.assertEqual(uplink, "eth0")
        self.assertEqual(saved["net.ipv4.ip_forward"], "0")
        self.assertIn(
            ["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", gateway.TUN_CIDR, "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-setup"],
            calls,
        )
        gateway.cleanup_tun("personalvpn0", "eth0", run=run, comment="pvvpn-setup", restore=saved)
        self.assertIn(
            ["iptables", "-t", "nat", "-D", "POSTROUTING", "-s", gateway.TUN_CIDR, "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-setup"],
            calls,
        )

    async def test_broker_peer_rejoins_and_becomes_owner_after_owner_death(self):
        written = []

        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        def record_write(fd, packet):
            written.append(packet)
            return len(packet)

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", return_value=("eth0", {})), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "write", side_effect=record_write), \
             patch.object(gateway.os, "close"):
            owner = gateway.PacketBroker("rejoinbr", lambda p: None)
            await owner.start()
            self.assertTrue(owner.owner)
            peer = gateway.PacketBroker("rejoinbr", lambda p: None)
            await peer.start()
            await asyncio.sleep(0.02)
            self.assertFalse(peer.owner)
            await owner.close()
            for _ in range(40):
                if peer.owner:
                    break
                await asyncio.sleep(0.05)
            self.assertTrue(peer.owner, "peer must rejoin and become owner after owner death")
            await peer.send_to_owner(b"resurrected")
            await asyncio.sleep(0.05)
            self.assertIn(b"resurrected", written)
            await peer.close()
class Round2SubnetTests(unittest.IsolatedAsyncioTestCase):
    def test_broker_subnet_is_deterministic_and_pins_golden_values(self):
        subnet = gateway.subnet_for_broker("testbroker")
        self.assertEqual(subnet.v4_cidr, "10.203.49.46.0/30")
        self.assertEqual(subnet.v4_gateway, "10.203.49.46.1/30")
        self.assertEqual(subnet.v6_gateway, "fd00:203:312e::1/64")
        self.assertEqual(subnet.v6_cidr, "fd00:203:312e::/64")
        self.assertEqual(gateway.subnet_for_broker("testbroker"), gateway.subnet_for_broker("testbroker"))
        other = gateway.subnet_for_broker("device42")
        self.assertEqual(other.v4_cidr, "10.203.26.1.0/30")
        self.assertNotEqual(subnet.v4_cidr, other.v4_cidr)

    def test_configure_tun_uses_legacy_subnet_when_unspecified(self):
        self.assertEqual(gateway.LEGACY_SUBNET.v4_gateway, gateway.TUN_ADDRESS)
        self.assertEqual(gateway.LEGACY_SUBNET.v4_cidr, gateway.TUN_CIDR)
        self.assertEqual(gateway.LEGACY_SUBNET.v6_gateway, gateway.TUN6_ADDRESS)
        self.assertEqual(gateway.LEGACY_SUBNET.v6_cidr, gateway.TUN6_CIDR)

    def test_configure_and_cleanup_use_per_broker_subnet(self):
        calls = []

        def run(args, **kwargs):
            calls.append(args)
            result = Mock(returncode=0, stdout="")
            if args[:2] == ["ip", "route"]:
                result.stdout = "default via 192.0.2.1 dev eth0\n"
            if args[0] in ("iptables", "ip6tables") and args[3] == "-C":
                result.returncode = 1
            if args[0] == "sysctl" and args[1] == "-n":
                result.stdout = "0"
            return result

        subnet = gateway.subnet_for_broker("device42")
        uplink, saved = gateway.configure_tun("personalvpn0", run=run, comment="pvvpn-device42", subnet=subnet)
        self.assertEqual(uplink, "eth0")
        self.assertIn(["ip", "addr", "replace", "10.203.26.1.1/30", "dev", "personalvpn0"], calls)
        self.assertIn(["ip", "-6", "addr", "replace", "fd00:203:1a01::1/64", "dev", "personalvpn0"], calls)
        self.assertIn(
            ["iptables", "-t", "nat", "-A", "POSTROUTING", "-s", "10.203.26.1.0/30", "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-device42"],
            calls,
        )
        self.assertIn(
            ["ip6tables", "-t", "nat", "-A", "POSTROUTING", "-s", "fd00:203:1a01::/64", "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-device42"],
            calls,
        )
        gateway.cleanup_tun("personalvpn0", "eth0", run=run, comment="pvvpn-device42", restore=saved, subnet=subnet)
        self.assertIn(
            ["iptables", "-t", "nat", "-D", "POSTROUTING", "-s", "10.203.26.1.0/30", "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-device42"],
            calls,
        )
        self.assertIn(
            ["ip6tables", "-t", "nat", "-D", "POSTROUTING", "-s", "fd00:203:1a01::/64", "-o", "eth0",
             "-j", "MASQUERADE", "-m", "comment", "--comment", "pvvpn-device42"],
            calls,
        )

    async def test_owner_passes_per_broker_subnet_to_configure_tun(self):
        seen = {}

        def capture_configure(name, run, comment, subnet):
            seen["subnet"] = subnet
            return ("eth0", {})

        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", side_effect=capture_configure), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "close"):
            owner = gateway.PacketBroker("device42", lambda p: None)
            await owner.start()
            self.assertEqual(seen.get("subnet"), gateway.subnet_for_broker("device42"))
            await owner.close()


class Round3BrokerRaceTests(unittest.IsolatedAsyncioTestCase):
    async def test_stale_socket_file_is_replaced_by_new_owner(self):
        dead_path = os.path.join("/tmp", "personalvpn-staleb.sock")
        s = socket.socket(socket.AF_UNIX)
        s.bind(dead_path)
        s.close()

        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", return_value=("eth0", {})), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "close"):
            owner = gateway.PacketBroker("staleb", lambda p: None)
            await owner.start()
            try:
                self.assertTrue(owner.owner)
            finally:
                await owner.close()
            self.assertFalse(os.path.exists(dead_path))
            try:
                os.unlink(dead_path)
            except FileNotFoundError:
                pass

    async def test_two_new_peers_racing_results_in_exactly_one_owner(self):
        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", return_value=("eth0", {})), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "close"):
            first = gateway.PacketBroker("freshr", lambda p: None)
            await first.start()
            self.assertTrue(first.owner)
            try:
                second = gateway.PacketBroker("freshr", lambda p: None)
                await second.start()
                self.assertFalse(second.owner, "only one process may own the TUN")
                self.assertIsNotNone(second.writer, "loser must join the winner as a peer")
                await second.close()
            finally:
                await first.close()
            try:
                os.unlink("/tmp/personalvpn-freshr.sock")
            except FileNotFoundError:
                pass

    async def test_takeover_joins_live_owner_instead_of_deposing_it(self):
        async def no_tun_reader(_):
            await asyncio.sleep(3600)

        def open_tun():
            return 99, "personalvpn0"

        with patch.object(gateway.PacketBroker, "tun_reader", new=no_tun_reader), \
             patch.object(gateway, "open_tun_device", side_effect=open_tun), \
             patch.object(gateway, "configure_tun", return_value=("eth0", {})), \
             patch.object(gateway, "cleanup_tun"), \
             patch.object(gateway.os, "close"):
            owner = gateway.PacketBroker("racebr", lambda p: None)
            await owner.start()
            self.assertTrue(owner.owner)
            try:
                original = gateway.asyncio.open_unix_connection
                state = {"first": True}

                async def fake_connect(path):
                    if state["first"]:
                        state["first"] = False
                        raise OSError("simulated refused/stale probe")
                    return await original(path)

                raced = gateway.PacketBroker("racebr", lambda p: None)
                with patch.object(gateway.asyncio, "open_unix_connection", side_effect=fake_connect):
                    await raced.start()
                self.assertFalse(raced.owner, "racer must join the live owner, not depose it")
                self.assertIsNotNone(raced.writer)
                await raced.close()
            finally:
                await owner.close()


if __name__ == "__main__":
    unittest.main()
