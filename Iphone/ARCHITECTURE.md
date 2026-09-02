# iPhone implementation architecture

## Data plane

`NEPacketTunnelProvider` owns the system VPN interface. It reads raw IPv4/IPv6 packets from `packetFlow` and sends `.packet` frames over authenticated SSH child sessions to the user's VPS. The VPS writes those packets to a temporary TUN interface; Linux forwarding/NAT performs the actual Internet routing. Flow-mode `OPEN/DATA` is an optional optimization, not the system-wide transport contract.

Production invariant: the three SSH raw-packet sessions feed one coordinated
remote TUN broker. The first gateway process owns/configures the TUN and NAT;
the other SSH gateway processes join over a permission-600 temporary Unix
socket. Return packets are round-robin assigned to exactly one SSH session,
and broker loss causes the owning gateway to be torn down and recreated by the
bounded reconnect path.

The VPS process is a temporary userspace gateway started through SSH. It receives `OPEN/DATA/FIN/RESET/CLOSE` frames, opens outbound sockets, and returns framed data. It has no public listener and is not our relay.

## Transport invariants

1. Every flow has one stable `streamID`.
2. A TCP flow is pinned to one SSH transport connection for its lifetime.
3. UDP datagrams may use the same transport assignment but are independently bounded and expire when idle.
4. A failed transport connection cannot corrupt frames belonging to another connection.
5. A reconnect never silently reuses an old stream ID.
6. A frame is rejected before allocation if its declared length exceeds the protocol limit.
7. The extension reports VPN connected only after SSH authentication, gateway handshake, and a real connectivity check succeed.

## Bootstrap modes

- Python stdin mode: stream a signed/embedded gateway script to a compatible `python3 -` process.
- Binary mode: stream a signed Go binary through SSH, verify it, execute it from a temporary path, then clean it up.
- Memory mode: optional Linux-specific execution from memory, only after operational diagnostics are available.

The app must not require `ssh -D`, `ssh -L`, `ssh -R`, or a public proxy port.

## iOS limits

The app target and Network Extension target must be separate Xcode targets. `PacketTunnelProvider` cannot be proven by macOS package tests. Device verification is required for entitlement, extension lifetime, background reconnect, sleep/wake, and network transitions.
