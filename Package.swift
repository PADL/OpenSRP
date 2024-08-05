// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let PlatformPackageDependencies: [Package.Dependency]
let PlatformTargetDependencies: [Target.Dependency]
let PlatformProducts: [Product]
let PlatformTargets: [Target]
let PlatformCSettings: [CSetting]
let PlatformLinkerSettings: [LinkerSetting]

#if os(Linux)
PlatformPackageDependencies = [.package(
  url: "https://github.com/PADL/IORingSwift",
  branch: "main"
)]

PlatformCSettings = [.unsafeFlags(["-I", "/usr/include/libnl3"])]
PlatformLinkerSettings = [.linkedLibrary("nl-3"), .linkedLibrary("nl-route-3")]

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
  .product(
    name: "IORingFoundation",
    package: "IORingSwift",
    condition: .when(platforms: [.linux])
  ),
]

PlatformProducts = [
  .library(
    name: "CNetLink",
    targets: ["CNetLink"]
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
    name: "portmon",
    targets: ["portmon"]
  ),
]
PlatformTargets = [
  .systemLibrary(
    name: "CNetLink",
    providers: [.apt(["libnl-3-dev"])]
  ),
  .target(
    name: "NetLink",
    dependencies: ["CNetLink",
                   .product(name: "CLinuxSockAddr", package: "SocketAddress"),
                   .product(name: "SystemPackage", package: "swift-system"),
                   .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
                   "AsyncExtensions"],
    cSettings: PlatformCSettings,
    linkerSettings: PlatformLinkerSettings
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
    name: "portmon",
    dependencies: ["MRP", "NetLink"],
    path: "Examples/portmon"
  ),
]

#elseif os(macOS) || os(iOS)
PlatformPackageDependencies = []
PlatformTargetDependencies = []
PlatformProducts = []
PlatformTargets = []
PlatformCSettings = []
PlatformLinkerSettings = []
#endif

let CommonPackageDependencies: [Package.Dependency] = [
  .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
  .package(url: "https://github.com/apple/swift-log", from: "1.5.4"),
  .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.0"),
  .package(url: "https://github.com/apple/swift-system", from: "1.2.1"),
  .package(url: "https://github.com/PADL/SocketAddress", from: "0.0.1"),
  .package(url: "https://github.com/lhoward/AsyncExtensions", branch: "linux"),
]

let CommonProducts: [Product] = [
  .library(
    name: "MRP",
    targets: ["MRP"]
  ),
]

let CommonTargets: [Target] = [
  .target(
    name: "MRP",
    dependencies: [
      "AsyncExtensions",
      "SocketAddress",
      .product(name: "Algorithms", package: "swift-algorithms"),
      .product(name: "AsyncAlgorithms", package: "swift-async-algorithms"),
      .product(name: "SystemPackage", package: "swift-system"),
      .product(name: "Logging", package: "swift-log"),
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
