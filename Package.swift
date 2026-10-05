// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "apfsfind",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "APFSFindCore", targets: ["APFSFindCore"]),
        .executable(name: "apfsfind", targets: ["apfsfind"]),
        .executable(name: "APFSFindDesktop", targets: ["APFSFindDesktop"])
    ],
    targets: [
        .target(name: "CAPFSShim", publicHeadersPath: "include"),
        .target(name: "APFSFindCore", dependencies: ["CAPFSShim"],
                linkerSettings: [.linkedFramework("CoreServices")]),
        .executableTarget(name: "apfsfind", dependencies: ["APFSFindCore"]),
        .executableTarget(name: "APFSFindDesktop", dependencies: ["APFSFindCore"],
                          linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("SwiftUI"), .linkedFramework("Carbon")]),
        .testTarget(name: "APFSFindDesktopTests", dependencies: ["APFSFindDesktop", "APFSFindCore"]),
        .testTarget(name: "APFSFindCoreTests", dependencies: ["APFSFindCore", "CAPFSShim"])
    ],
    swiftLanguageModes: [.v6]
)
