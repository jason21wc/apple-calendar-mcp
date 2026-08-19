// What these tests protect
//
// A probe label is attacker-influenceable in the only sense that matters here: it comes
// straight off the command line of a process an MCP client spawns, and it becomes part of a
// filename inside ~/.local/state/apple-calendar-mcp -- a 0700 directory that Phase 5 will
// fill with a mutation journal and pre-state snapshots of real calendar content. A label
// that can steer that write outside the directory, or overwrite a neighbouring file, is a
// containment failure rather than a cosmetic one.
//
// The safety property is about the COMPOSED PATH, not about the sanitiser in isolation, so
// that is what most of these tests assert.

import Testing
import Foundation
@testable import apple_calendar_mcp

@Suite("Probe label sanitiser")
struct ProbeLabelSanitiserTests {

    /// Inputs chosen for what they attack, not for coverage. Kept in one place so every
    /// property below is checked against all of them.
    static let hostileLabels: [(name: String, label: String)] = [
        ("relative traversal",      "../../evil"),
        ("deep traversal",          "../../../../../../../../etc/passwd"),
        ("absolute path",           "/etc/passwd"),
        ("home-relative",           "~/.ssh/authorized_keys"),
        ("bare parent",             ".."),
        ("bare dot",                "."),
        ("dot chain",               "...."),
        ("collapsed traversal",     "....//....//x"),
        ("forward separator",       "a/b"),
        ("backslash separator",     "a\\b"),
        ("classic mac separator",   "a:b"),
        ("embedded NUL",            "a\u{0000}b"),
        ("leading NUL",             "\u{0000}etc"),
        ("newline",                 "a\nb"),
        ("carriage return",         "a\rb"),
        ("tab",                     "a\tb"),
        ("space",                   "a b"),
        ("shell metacharacters",    "$(rm -rf ~)`id`;|&"),
        ("glob",                    "*"),
        ("question glob",           "?"),
        ("quote",                   "a\"b'c"),
        ("right-to-left override",  "\u{202E}gnp.evil"),
        ("zero width joiner",       "a\u{200D}b"),
        ("emoji",                   "\u{1F680}\u{1F680}"),
        ("empty",                   ""),
        ("single space only",       " "),
        ("64 ascii",                String(repeating: "a", count: 64)),
        ("100 ascii",               String(repeating: "a", count: 100)),
        ("1000 ascii",              String(repeating: "a", count: 1000)),
        ("1000 slashes",            String(repeating: "/", count: 1000)),
        ("astral letters",          String(repeating: "\u{1D518}", count: 100)),
        ("cjk",                     String(repeating: "\u{4E2D}", count: 100)),
        ("combining marks",         "a" + String(repeating: "\u{0301}", count: 500)),
    ]

    // MARK: - The property that matters: the write stays inside the state directory

    @Test("no label can steer the probe write out of the state directory",
          arguments: hostileLabels)
    func composedPathStaysInsideTheStateDirectory(name: String, label: String) {
        // A stand-in for `stateDir`. The real one is a @MainActor global in main.swift and
        // reading it from a test host SEGVs, so the composition is reproduced here exactly
        // as writeProbe performs it: stateDir / "probe-<sanitised>.json".
        let base = URL(fileURLWithPath: "/tmp/apple-calendar-mcp-test-state", isDirectory: true)
        let file = base.appendingPathComponent("probe-\(sanitize(label)).json").standardizedFileURL

        #expect(file.deletingLastPathComponent().standardizedFileURL.path == base.standardizedFileURL.path,
                "[\(name)] escaped to \(file.path)")
        #expect(file.path.hasPrefix(base.path + "/"), "[\(name)] left the base directory: \(file.path)")
        #expect(!file.path.contains("/.."), "[\(name)] path contains an unresolved parent reference")
        #expect(file.pathExtension == "json", "[\(name)] lost its .json extension: \(file.path)")
        #expect(file.lastPathComponent.hasPrefix("probe-"),
                "[\(name)] lost the probe- prefix: \(file.lastPathComponent)")
    }

    @Test("no sanitised label contains a path separator or any other filename metacharacter",
          arguments: hostileLabels)
    func outputContainsNoDangerousCharacter(name: String, label: String) {
        let out = sanitize(label)
        // A denylist, deliberately, rather than restating the implementation's allowlist.
        // Restating the allowlist would pass for any implementation that happened to match
        // itself, including a broken one.
        let forbidden: [(String, Character)] = [
            ("forward slash", "/"), ("backslash", "\\"), ("colon", ":"), ("NUL", "\u{0000}"),
            ("newline", "\n"), ("carriage return", "\r"), ("tab", "\t"), ("space", " "),
            ("tilde", "~"), ("dollar", "$"), ("backtick", "`"), ("double quote", "\""),
            ("single quote", "'"), ("semicolon", ";"), ("pipe", "|"), ("ampersand", "&"),
            ("asterisk", "*"), ("question mark", "?"), ("less than", "<"), ("greater than", ">"),
            ("percent", "%"), ("RTL override", "\u{202E}"),
        ]
        for (described, character) in forbidden {
            #expect(!out.contains(character),
                    "[\(name)] sanitised output retains a \(described): \(String(reflecting: out))")
        }
    }

    @Test("specific traversal attempts are neutralised into ordinary filename text")
    func traversalBecomesInertText() {
        #expect(sanitize("../../evil") == "..-..-evil")
        #expect(sanitize("/etc/passwd") == "-etc-passwd")
        #expect(sanitize("a/b\\c:d") == "a-b-c-d")
        #expect(sanitize("a\u{0000}b") == "a-b")
    }

    // MARK: - Boundaries

    @Test("the label is capped at 64 characters")
    func labelIsCappedAt64Characters() {
        #expect(sanitize(String(repeating: "a", count: 63)).count == 63)
        #expect(sanitize(String(repeating: "a", count: 64)).count == 64)
        #expect(sanitize(String(repeating: "a", count: 65)).count == 64)
        #expect(sanitize(String(repeating: "a", count: 1000)).count == 64)
        #expect(sanitize(String(repeating: "/", count: 1000)) == String(repeating: "-", count: 64))
    }

    @Test("an empty label produces an empty result rather than a crash or a default")
    func emptyLabelIsEmpty() {
        #expect(sanitize("") == "")
        // Composed, that is "probe-.json" -- ugly but contained. The default label for a
        // bare --probe is supplied by Command.parse, not by the sanitiser.
        #expect(sanitize(" ") == "-")
    }

    @Test("sanitising an already-sanitised label changes nothing")
    func sanitiseIsIdempotent() {
        for (name, label) in Self.hostileLabels {
            let once = sanitize(label)
            #expect(sanitize(once) == once,
                    "[\(name)] not idempotent: \(String(reflecting: once)) -> \(String(reflecting: sanitize(once)))")
        }
    }

    @Test("sanitising never lengthens a label in characters")
    func sanitiseNeverGrows() {
        for (name, label) in Self.hostileLabels {
            #expect(sanitize(label).count <= min(label.count, 64), "[\(name)] grew")
        }
    }

    // MARK: - Where the boundary actually is

    @Test("the sanitiser alone does not neutralise `..`; only the caller's probe- prefix does")
    func parentReferenceSurvivesSanitisationAndIsContainedByTheCaller() {
        // Recorded because it is load-bearing and invisible. `sanitize` permits "." and so
        // returns ".." unchanged -- a parent-directory reference. Nothing goes wrong today
        // only because writeProbe always wraps the result as "probe-<label>.json". Any
        // future caller that uses a sanitised label as a bare path component inherits a
        // directory-traversal primitive from a function whose doc comment says labels
        // "become filenames, so anything outside a safe set is replaced rather than trusted".
        #expect(sanitize("..") == "..")
        #expect(sanitize(".") == ".")

        let base = URL(fileURLWithPath: "/tmp/apple-calendar-mcp-test-state", isDirectory: true)

        // Contained, because of the prefix and suffix:
        let wrapped = base.appendingPathComponent("probe-\(sanitize("..")).json").standardizedFileURL
        #expect(wrapped.path == base.path + "/probe-...json")

        // NOT contained, if a caller ever drops them. This is the shape of the future bug.
        let bare = base.appendingPathComponent(sanitize("..")).standardizedFileURL
        #expect(bare.path != base.path + "/..")
        #expect(bare.path == "/tmp", "if this ever stops resolving upward, the note above can be deleted")
    }

    @Test("the cap bounds the filename in BYTES, not in grapheme clusters")
    func capBoundsFilenameInBytes() throws {
        // A Character is a grapheme cluster, so a byte budget cannot be enforced by
        // counting Characters: one base letter plus 500 combining marks is a SINGLE
        // Character that expands to about 1 kB of UTF-8. An earlier `prefix(64)` let it
        // through and the probe write failed outright with "File name too long" -- on the
        // file that is this tool's entire deliverable.
        let label = "a" + String(repeating: "\u{0301}", count: 500)
        let sanitised = sanitize(label)

        #expect(sanitised.utf8.count <= 64,
                "sanitised label is \(sanitised.utf8.count) bytes; the budget is 64")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-calendar-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("probe-\(sanitised).json")
        #expect(file.lastPathComponent.utf8.count <= 255,
                "filename is \(file.lastPathComponent.utf8.count) bytes; the OS limit is 255")
        try Data("{}".utf8).write(to: file, options: [.atomic])
    }

    @Test("a sanitised ASCII label always produces a writable filename")
    func asciiLabelsAlwaysProduceAWritableFile() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("apple-calendar-mcp-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, label) in Self.hostileLabels where label.allSatisfy(\.isASCII) {
            let file = dir.appendingPathComponent("probe-\(sanitize(label)).json")
            #expect(throws: Never.self, "[\(name)] could not be written as \(file.lastPathComponent)") {
                try Data("{}".utf8).write(to: file, options: [.atomic])
            }
        }
    }

    @Test("distinct hostile labels do not all collapse onto the same filename")
    func sanitiserDoesNotCollapseEverythingOntoOneName() {
        // Guards the opposite failure from traversal: a sanitiser that returned a constant
        // would pass every containment assertion above while making every probe overwrite
        // the previous one.
        #expect(sanitize("phase1") == "phase1")
        #expect(sanitize("spawned") == "spawned")
        #expect(sanitize("codex-2026-08-18_v1.2") == "codex-2026-08-18_v1.2")
        #expect(sanitize("a") != sanitize("b"))
    }
}
