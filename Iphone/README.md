# Personal VPN — iPhone

Native iOS client for the Personal VPN product. The client exposes a system VPN through `NetworkExtension`, while its data plane uses a custom flow protocol carried over a pool of SSH connections to the user's VPS.

## Current implementation

- `VPNCore` contains the transport framing and connection state machine.
- `VPNCore` also contains the SwiftNIO SSH connection factory and child-channel framing codec.
- `Gateway/gateway.py` is the user-VPS stdin/stdout gateway; it has no public listener.
- The gateway supports both flow mode and on-demand Linux TUN raw-packet mode.
- Raw-packet mode uses a single temporary Unix-socket TUN broker: one SSH gateway owns/configures the TUN, while the other SSH sessions join it and receive distinct return-packet assignments.
- SSH authentication supports passwords and Ed25519 private keys. Keys are parsed in-process and only the normalized seed is stored in Keychain; encrypted keys and unsupported algorithms fail explicitly.
- `Tests/VPNCoreTests` contains red/edge tests for malformed frames, state transitions, reconnect backoff, and background-safe intent handling.
- `App/` contains the SwiftUI/Network Extension integration blueprint to add to an Xcode iOS app target.
- `CHECKLIST.md` is the delivery checklist, including device-only verification items.

## Run the core tests

```sh
cd Iphone
SWIFT_MODULECACHE_PATH=/tmp/personalvpn-swift-modules \
CLANG_MODULE_CACHE_PATH=/tmp/personalvpn-clang-modules \
swift test --disable-sandbox
```

The hand-authored Xcode project uses Swift Package dependencies. On the
current Xcode toolchain, build with the package output directory normalized:

```sh
xcodebuild -project PersonalVPN.xcodeproj -scheme PersonalVPN -sdk iphoneos \
  -configuration Debug -derivedDataPath /tmp/PersonalVPNBuild \
  CONFIGURATION_BUILD_DIR=/tmp/PersonalVPNBuild/Build/Products/Debug \
  CODE_SIGNING_ALLOWED=NO build
```

The real `NEPacketTunnelProvider` lifecycle, VPN entitlement, background reconnect, and App Store signing must be verified with an Apple Developer team and a physical iPhone. Simulator tests cannot prove those behaviors.
