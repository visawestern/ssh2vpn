// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SSH2VPN",
    platforms: [.iOS(.v16), .macOS(.v10_15)],
    products: [
        .library(name: "VPNCore", targets: ["VPNCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh.git", from: "0.13.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0")
    ],
    targets: [
        .target(name: "VPNCore", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
            .product(name: "Crypto", package: "swift-crypto")
        ]),
        .testTarget(name: "VPNCoreTests", dependencies: ["VPNCore"])
    ]
)
