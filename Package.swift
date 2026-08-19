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
        ),

        // A test target CAN depend on this executable target, and that was worth checking
        // rather than assuming: the `unsafeFlags` above only bar this package from being
        // resolved as somebody else's DEPENDENCY. They place no restriction on a target
        // inside this same package, so no library-extraction restructure is needed.
        // Verified by building AND running, not by reading the manifest documentation.
        //
        // WHAT THIS LINKAGE DOES NOT BUY. main.swift is top-level code, so its globals
        // (`disclaimMode`, `stateDir`, `store`) are initialised by `main` -- which never
        // runs in a test host. They are also @MainActor-isolated, so the compiler happily
        // lets a @MainActor test read them and the process then SEGVs (measured: signal 11,
        // whole run lost). Everything that touches them -- Doctor.run, SetupFlow.run,
        // printVersion, writeProbe -- is reachable only through a real subprocess. See
        // Tests/AppleCalendarMCPTests/ReexecProcessTests.swift.
        //
        // FRAMEWORK NOTE. `import Testing` needs no package dependency on Swift 6.3, but on
        // a Command Line Tools-only machine Testing.framework is not on SwiftPM's default
        // search path and plain `swift test` cannot find the module. Use ./scripts/test.sh,
        // which derives the paths from `xcode-select -p` rather than hardcoding them.
        // XCTest is not an alternative: Command Line Tools ships no XCTest.swiftmodule.
        .testTarget(
            name: "AppleCalendarMCPTests",
            dependencies: ["apple-calendar-mcp"],
            path: "Tests/AppleCalendarMCPTests"
        ),
    ]
)
