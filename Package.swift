// swift-tools-version: 6.0
// MoshKit: pure-Swift mosh client core. Builds on Linux (dev container) and Apple platforms.
import PackageDescription

let nioSSH: Target.Dependency = .product(name: "NIOSSH", package: "swift-nio-ssh")
let nioCore: Target.Dependency = .product(name: "NIOCore", package: "swift-nio")
let nioPosix: Target.Dependency = .product(name: "NIOPosix", package: "swift-nio")
let nioTS: Target.Dependency = .product(
    name: "NIOTransportServices", package: "swift-nio-transport-services",
    condition: .when(platforms: [.iOS, .macOS]))
let crypto: Target.Dependency = .product(name: "Crypto", package: "swift-crypto")
let cryptoExtrasLinux: Target.Dependency = .product(
    name: "CryptoExtras", package: "swift-crypto", condition: .when(platforms: [.linux]))

let package = Package(
    name: "MoshKit",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [
        .library(name: "MoshKit", targets: [
            "MoshCrypto", "MoshWire", "MoshTransport", "MoshTerminal", "MoshResume",
            "MoshKeys", "MoshBootstrap", "MoshSession",
        ]),
        .executable(name: "moshcli", targets: ["moshcli"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"6.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/apple/swift-nio-ssh.git", exact: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.20.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib", providers: [.apt(["zlib1g-dev"])]),
        .target(name: "MoshCrypto", dependencies: [cryptoExtrasLinux]),
        .target(name: "MoshWire", dependencies: ["CZlib", "MoshCrypto"]),
        .target(name: "MoshTransport", dependencies: ["MoshCrypto", "MoshWire"]),
        .target(name: "MoshTerminal"),
        .target(name: "MoshKeys", dependencies: [crypto]),
        .target(name: "MoshBootstrap", dependencies: ["MoshKeys", crypto, nioSSH, nioCore, nioPosix, nioTS]),
        .target(name: "MoshSession", dependencies: [
            "MoshCrypto", "MoshWire", "MoshTransport", "MoshTerminal", "MoshKeys", "MoshBootstrap",
        ]),
        // MoshResume stores what MoshSession exports, so it is above the facade, not below it.
        .target(name: "MoshResume", dependencies: ["MoshCrypto", "MoshTransport", "MoshTerminal", "MoshSession"]),
        .executableTarget(name: "moshcli", dependencies: [
            "MoshCrypto", "MoshWire", "MoshTransport", "MoshTerminal", "MoshResume", "MoshKeys", "MoshBootstrap",
            "MoshSession",
        ]),
        // Helpers shared by test targets (spawn mosh-server, temp dirs, hex). Not part of the library product.
        .target(name: "MoshTestSupport", path: "Tests/MoshTestSupport"),
        .testTarget(name: "MoshCryptoTests", dependencies: ["MoshCrypto", "MoshTestSupport"]),
        .testTarget(name: "MoshWireTests", dependencies: ["MoshWire", "MoshCrypto", "MoshTestSupport"]),
        .testTarget(name: "MoshTransportTests", dependencies: ["MoshTransport", "MoshWire", "MoshCrypto", "MoshTestSupport"]),
        .testTarget(name: "MoshTerminalTests", dependencies: ["MoshTerminal", "MoshTestSupport"], exclude: ["Corpus", "Support"]),
        .testTarget(name: "MoshResumeTests", dependencies: [
            "MoshResume", "MoshSession", "MoshTransport", "MoshTerminal", "MoshWire", "MoshCrypto", "MoshTestSupport",
        ]),
        .testTarget(name: "MoshKeysTests", dependencies: ["MoshKeys", "MoshTestSupport"]),
        .testTarget(name: "MoshBootstrapTests", dependencies: ["MoshBootstrap", "MoshKeys", "MoshTestSupport"]),
        .testTarget(name: "MoshSessionTests", dependencies: [
            "MoshSession", "MoshTerminal", "MoshTransport", "MoshWire", "MoshCrypto", "MoshBootstrap", "MoshTestSupport",
        ]),
        .testTarget(name: "SurfaceFeedTests", dependencies: [
            "MoshTerminal", "MoshTestSupport", .product(name: "SwiftTerm", package: "SwiftTerm"),
        ]),
    ],
    swiftLanguageModes: [.v5]
)
