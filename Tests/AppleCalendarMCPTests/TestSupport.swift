// Shared locators. Everything here is derived from #filePath, so nothing in this suite
// depends on where the repository happens to live on any particular machine.

import Foundation

enum Repo {

    /// The package root, found by walking up from this source file until Package.swift
    /// appears. Deliberately not a hardcoded path and not $PWD -- `swift test` does not
    /// promise a working directory.
    static let root: URL = {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if FileManager.default.fileExists(
                atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        fatalError("could not locate Package.swift above \(#filePath)")
    }()

    static var scriptsDirectory: URL { root.appendingPathComponent("scripts") }

    static func source(_ relativePath: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The just-built executable. `swift test` builds the executable target as a dependency
    /// of the test target, so this is present whenever the suite runs; if it is missing that
    /// is itself a finding and the test should fail rather than quietly pass.
    ///
    /// SwiftPM puts the product under .build/<triple>/<config> and usually -- but not
    /// always -- also links .build/<config> to it, so both are tried.
    static func builtExecutable() throws -> URL {
        let fm = FileManager.default
        let buildDir = root.appendingPathComponent(".build")
        var candidates: [URL] = []
        for config in ["debug", "release"] {
            candidates.append(buildDir.appendingPathComponent("\(config)/apple-calendar-mcp"))
        }
        if let entries = try? fm.contentsOfDirectory(atPath: buildDir.path) {
            for entry in entries where entry.contains("-apple-macos") {
                for config in ["debug", "release"] {
                    candidates.append(buildDir
                        .appendingPathComponent(entry)
                        .appendingPathComponent("\(config)/apple-calendar-mcp"))
                }
            }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw TestSupportError.executableNotBuilt(searched: candidates.map(\.path))
    }
}

enum TestSupportError: Error, CustomStringConvertible {
    case executableNotBuilt(searched: [String])

    var description: String {
        switch self {
        case .executableNotBuilt(let searched):
            return "apple-calendar-mcp was not found. Searched:\n  " + searched.joined(separator: "\n  ")
        }
    }
}

struct ProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var combined: String { stdout + stderr }
}

enum Runner {

    /// Run a command with an EXPLICIT environment.
    ///
    /// Explicit, not inherited, for two reasons. First, an inherited
    /// APPLE_CALENDAR_MCP_DISCLAIMED or ..._REEXEC_DEPTH from the developer's shell would
    /// silently decide the answer of the very tests that exist to check those variables.
    /// Second, it keeps the child's PATH pinned, so a shimmed tool on the developer's PATH
    /// cannot influence a result.
    @discardableResult
    static func run(_ executable: URL,
                    arguments: [String],
                    environment: [String: String] = [:],
                    workingDirectory: URL? = nil,
                    timeout: TimeInterval = 30) throws -> ProcessResult {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"].merging(environment) { _, new in new }
        if let workingDirectory { task.currentDirectoryURL = workingDirectory }

        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        task.standardInput = FileHandle.nullDevice

        try task.run()

        // Read before waiting: a >64 KiB burst on either pipe would otherwise deadlock the
        // child against a test that is blocked in waitUntilExit. This is the same class of
        // mistake the shell suite lints for.
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while task.isRunning && Date() < deadline { usleep(5_000) }
        if task.isRunning {
            task.terminate()
            task.waitUntilExit()
            throw TestRunnerError.timedOut(seconds: timeout)
        }
        task.waitUntilExit()

        return ProcessResult(exitCode: task.terminationStatus,
                             stdout: String(decoding: outData, as: UTF8.self),
                             stderr: String(decoding: errData, as: UTF8.self))
    }

    static func bash(_ scriptPath: URL,
                     arguments: [String] = [],
                     environment: [String: String] = [:],
                     workingDirectory: URL? = nil,
                     timeout: TimeInterval = 120) throws -> ProcessResult {
        try run(URL(fileURLWithPath: "/bin/bash"),
                arguments: [scriptPath.path] + arguments,
                environment: environment,
                workingDirectory: workingDirectory,
                timeout: timeout)
    }
}

enum TestRunnerError: Error, CustomStringConvertible {
    case timedOut(seconds: TimeInterval)
    var description: String {
        switch self {
        case .timedOut(let s): return "process did not exit within \(s)s"
        }
    }
}
