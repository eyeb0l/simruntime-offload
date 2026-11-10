// swift-tools-version: 5.10

import PackageDescription

// No dependencies, deliberately: the tool should be small enough to audit in
// an afternoon, and a login agent should not pull in code nobody has read.
let package = Package(
    name: "simruntime-offload",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "SimRuntimeOffloadCore"),
        .executableTarget(
            name: "simruntime-offload",
            dependencies: ["SimRuntimeOffloadCore"]
        ),
        .testTarget(
            name: "SimRuntimeOffloadCoreTests",
            dependencies: ["SimRuntimeOffloadCore"],
            // Recorded output of `simctl` and `diskutil`, scrubbed of
            // machine-specific identifiers.
            resources: [.copy("Fixtures")]
        ),
    ]
)
