// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let PlatformPackageDependencies: [Package.Dependency]
let PlatformTargetDependencies: [Target.Dependency]
let PlatformProducts: [Product]
let PlatformTargets: [Target]
var PlatformCSettings: [CSetting] = []
var PlatformLinkerSettings: [LinkerSetting] = []

#if os(Linux)
PlatformPackageDependencies = [
  .package(
    url: "https://github.com/PADL/IORingSwift",
    branch: "main"
  ),
  .package(
    url: "https://github.com/PADL/NetLinkSwift",
    branch: "main"
  ),
]

PlatformTargetDependencies = [
  .product(
    name: "NetLink",
    package: "NetLinkSwift"
  ),
  .product(
    name: "IORing",
    package: "IORingSwift"
  ),
  .product(
    name: "IORingUtils",
    package: "IORingSwift"
  ),
]

PlatformProducts = [
  .executable(
    name: "mrpd",
    targets: ["MRPDaemon"]
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
  .executableTarget(
    name: "MRPDaemon",
    dependencies: [
      "MRP",
      .product(name: "ArgumentParser", package: "swift-argument-parser"),
      .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
    ]
  ),
  .executableTarget(
    name: "portmon",
    dependencies: ["MRP"],
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
    name: "IEEE802",
    dependencies: [
      .product(name: "SystemPackage", package: "swift-system"),
    ]
  ),
  .target(
    name: "MarvellRMU",
    dependencies: [
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
      .swiftLanguageMode(.v5),
      .enableExperimentalFeature("StrictConcurrency"),
    ],
    linkerSettings: PlatformLinkerSettings
  ),
  .target(
    name: "MRP",
    dependencies: [
      "IEEE802",
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
      .swiftLanguageMode(.v5),
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
    .macOS(.v15),
  ],
  products: CommonProducts + PlatformProducts,
  dependencies: CommonPackageDependencies + PlatformPackageDependencies,
  targets: CommonTargets + PlatformTargets
)
