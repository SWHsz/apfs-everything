// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apfsfind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "APFSFindCore", targets: ["APFSFindCore"]),
        .executable(name: "apfsfind", targets: ["apfsfind"])
    ],
    targets: [
        .target(name: "CAPFSShim", publicHeadersPath: "include"),
        .target(name: "APFSFindCore", dependencies: ["CAPFSShim"],
                linkerSettings: [.linkedFramework("CoreServices")]),
        .executableTarget(name: "apfsfind", dependencies: ["APFSFindCore"]),
        .testTarget(name: "APFSFindCoreTests", dependencies: ["APFSFindCore", "CAPFSShim"])
    ],
    swiftLanguageModes: [.v6]
)
