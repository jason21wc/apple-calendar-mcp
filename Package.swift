// swift-tools-version: 6.0
import PackageDescription

// The executable name is load-bearing, not cosmetic: macOS TCC binds the Calendar grant to
// this binary's code-signing identity. It must be the FINAL name from the first build, or
// the Phase 1 result does not transfer to the real server.
// CONSUMPTION NOTE: `unsafeFlags` below means SwiftPM will refuse to resolve this package
// as a DEPENDENCY. Distribution is clone-and-build only, which is deliberate -- the binary
// must be signed with a stable local certificate and granted Calendar access at its final
// installed path, so a transitive dependency could never work anyway.

let package = Package(
    name: "apple-calendar-mcp",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "apple-calendar-mcp",
            path: "Sources/apple-calendar-mcp",
            exclude: ["Info.plist", "Entitlements.plist"],
            linkerSettings: [
                // NOTE: this path is resolved against the LINKER's working directory,
                // which SwiftPM inherits from the invoker -- not the package root. Build
                // from the repo root, or `--package-path` will link without the section.
                // Also note SwiftPM does not treat Info.plist as a link input, so editing
                // the usage string alone will not trigger a relink; touch a source file.
                //
                // An SPM executable has no bundle, so it cannot carry an Info.plist the
                // normal way. Embedding it into the Mach-O __TEXT,__info_plist section is
                // the only way TCC can read NSCalendarsFullAccessUsageDescription.
                // Without it the permission prompt shows no reason string and macOS may
                // refuse to prompt at all.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/apple-calendar-mcp/Info.plist",
                ])
            ]
        )
    ]
)
