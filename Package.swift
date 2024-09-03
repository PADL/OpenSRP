// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let PlatformPackageDependencies: [Package.Dependency]
let PlatformTargetDependencies: [Target.Dependency]
let PlatformProducts: [Product]
let PlatformTargets: [Target]
var PlatformCSettings: [CSetting] = []
var PlatformLinkerSettings: [LinkerSetting] = []

#if os(Linux)
PlatformPackageDependencies = [.package(
  url: "https://github.com/PADL/IORingSwift",
  branch: "main"
)]

let LocalLibNL = false // use locally built libnl, for debugging

if LocalLibNL {
  PlatformCSettings = [.unsafeFlags(["-I", "/usr/local/include/libnl3"])]
  PlatformLinkerSettings = [.unsafeFlags(["-L", "/usr/local/lib"])]
} else {
  PlatformCSettings = [.unsafeFlags(["-I", "/usr/include/libnl3"])]
}

PlatformLinkerSettings += [
  .linkedLibrary("nl-3"),
  .linkedLibrary("nl-route-3"),
  .linkedLibrary("nl-nf-3"),
]

PlatformTargetDependencies = [
  "NetLink",
  .product(
    name: "IORing",
    package: "IORingSwift",
    condition: .when(platforms: [.linux])
  ),
  .product(
    name: "IORingUtils",
    package: "IORingSwift",
    condition: .when(platforms: [.linux])
  ),
]

PlatformProducts = [
  .library(
    name: "NetLink",
    targets: ["NetLink"]
  ),
  .executable(
    name: "mrpd",
    targets: ["MRPDaemon"]
  ),
  .executable(
    name: "nldump",
    targets: ["nldump"]
  ),
  .executable(
    name: "nlmonitor",
    targets: ["nlmonitor"]
  ),
  .executable(
    name: "nltool",
    targets: ["nltool"]
  ),
  .executable(
    name: "portmon",
    targets: ["portmon"]
  ),
  .executable(
    name: "pmctool",
    targets: ["pmctool"]
  ),
]
PlatformTargets = [
  .systemLibrary(
    name: "CNetLink",
    providers: [
      .apt(["libnl-3-dev", "libnl-route-3-dev", "libnl-nf-3"]),
    ]
  ),
  .target(
    name: "NetLink",
    dependencies: ["CNetLink",
                   "Locking",
                   .product(name: "CLinuxSockAddr", package: "SocketAddress"),
                   .product(name: "SocketAddress", package: "SocketAddress"),
                   .product(name: "SystemPackage", package: "swift-system"),
                   .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                   "AsyncExtensions"],
    cSettings: PlatformCSettings,
    linkerSettings: PlatformLinkerSettings
  ),
  .executableTarget(
    name: "MRPDaemon",
    dependencies: [
      "MRP",
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
      .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
    ]
  ),
  .executableTarget(
    name: "nldump",
    dependencies: ["NetLink"],
    path: "Examples/nldump"
  ),
  .executableTarget(
    name: "nlmonitor",
    dependencies: ["NetLink"],
    path: "Examples/nlmonitor"
  ),
  .executableTarget(
    name: "nltool",
    dependencies: ["NetLink", .product(name: "IORingUtils", package: "IORingSwift")],
    path: "Examples/nltool"
  ),
  .executableTarget(
    name: "portmon",
    dependencies: ["MRP", "NetLink"],
    path: "Examples/portmon"
  ),
  .executableTarget(
    name: "pmctool",
    dependencies: ["PMC"],
    path: "Examples/pmctool"
  ),
]

#elseif os(macOS) || os(iOS)
PlatformPackageDependencies = []
PlatformTargetDependencies = []
PlatformProducts = []
PlatformTargets = []
#endif

let CommonPackageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
  .package(url: "https://github.com/apple/swift-log", from: "1.5.4"),
  .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
  .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
  .package(url: "https://github.com/apple/swift-argument-parser", from: "1.2.0"),
  .package(url: "https://github.com/PADL/SocketAddress", from: "0.0.1"),
  .package(url: "https://github.com/lhoward/AsyncExtensions", branch: "linux"),
  .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.3.0"),
]

let CommonProducts: [Product] = [
  .library(
    name: "MarvellRMU",
    targets: ["MarvellRMU"]
  ),
  .library(
    name: "MRP",
    targets: ["MRP"]
  ),
]

let CommonTargets: [Target] = [
  .target(
    name: "Locking"
  ),
  .target(
    name: "IEEE802",
    dependencies: [
      .product(name: "SystemPackage", package: "swift-system"),
    ]
  ),
  .target(
    name: "MarvellRMU",
    dependencies: [
      "Locking",
      "IEEE802",
      "AsyncExtensions",
      "SocketAddress",
      .product(name: "Algorithms", package: "swift-algorithms"),
      .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      .product(name: "Logging", package: "swift-log"),
      .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      .product(name: "SystemPackage", package: "swift-system"),
    ]
  ),
  .target(
    name: "PMC",
    dependencies: [
      "IEEE802",
      "AsyncExtensions",
      "SocketAddress",
      .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      .product(name: "SystemPackage", package: "swift-system"),
    ] + PlatformTargetDependencies,
    cSettings: PlatformCSettings,
    swiftSettings: [
      .enableExperimentalFeature("StrictConcurrency"),
    ],
    linkerSettings: PlatformLinkerSettings
  ),
  .target(
    name: "MRP",
    dependencies: [
      "IEEE802",
      "Locking",
      "AsyncExtensions",
      "SocketAddress",
      "MarvellRMU",
      "PMC",
      .product(name: "Algorithms", package: "swift-algorithms"),
      .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      .product(name: "Logging", package: "swift-log"),
      .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
      .product(name: "SystemPackage", package: "swift-system"),
    ] + PlatformTargetDependencies,
    cSettings: PlatformCSettings,
    swiftSettings: [
      .enableExperimentalFeature("StrictConcurrency"),
    ],
    linkerSettings: PlatformLinkerSettings
  ),
  .testTarget(
    name: "MRPTests",
    dependencies: ["MRP"]
  ),
]

let package = Package(
  name: "SwiftMRP",
  platforms: [
    .macOS(.v14),
  ],
  products: CommonProducts + PlatformProducts,
  dependencies: CommonPackageDependencies + PlatformPackageDependencies,
  targets: CommonTargets + PlatformTargets,
  swiftLanguageVersions: [.v5]
)
