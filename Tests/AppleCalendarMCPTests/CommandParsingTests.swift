// What these tests protect
//
// `Command.parse` decides what an unrecognised argument means. It once fell through to
// `.serve`, which is the worst available answer: a typo'd flag made the process enter the
// stdio server path instead of saying anything, and the caller saw a hang or an unexplained
// exit rather than "unknown option". Fail-closed here is a correctness property, not taste.
//
// `--grant` is the pre-0.2 spelling of `--setup`. It is documented as still working and is
// still printed by --help, so it needs a test of its own rather than living on as folklore.

import Testing
@testable import apple_calendar_mcp

/// `Command` is not Equatable in the shipping code and this suite does not add a conformance
/// to it -- production types should not grow API to suit tests. This mapping exists only so
/// failures print something readable, and `shapesAreDistinguishable` below guards against
/// the obvious way it could make the tests vacuous.
private enum Shape: Equatable, CustomStringConvertible {
    case serve, setup, doctor, version, help
    case probe(String)
    case unknown(String)

    init(_ command: Command) {
        switch command {
        case .serve:              self = .serve
        case .setup:              self = .setup
        case .doctor:             self = .doctor
        case .version:            self = .version
        case .help:               self = .help
        case .probe(let label):   self = .probe(label)
        case .unknown(let flag):  self = .unknown(flag)
        }
    }

    var description: String {
        switch self {
        case .serve: return ".serve"
        case .setup: return ".setup"
        case .doctor: return ".doctor"
        case .version: return ".version"
        case .help: return ".help"
        case .probe(let l): return ".probe(\(l))"
        case .unknown(let f): return ".unknown(\(f))"
        }
    }
}

private func shape(_ args: [String]) -> Shape { Shape(Command.parse(args)) }

@Suite("Command-line parsing")
struct CommandParsingTests {

    @Test("the shape mapping used by this suite can actually tell the cases apart")
    func shapesAreDistinguishable() {
        // Without this, a mapping that collapsed .unknown onto .serve would make the single
        // most important test in this file pass while proving nothing.
        let all: [Shape] = [Shape(.serve), Shape(.setup), Shape(.doctor), Shape(.version),
                            Shape(.help), Shape(.probe(label: "x")), Shape(.unknown("x"))]
        #expect(Set(all.map(\.description)).count == all.count)
        #expect(Shape(.serve) != Shape(.unknown("")))
        #expect(Shape(.probe(label: "a")) != Shape(.probe(label: "b")))
        #expect(Shape(.unknown("a")) != Shape(.unknown("b")))
    }

    // MARK: - The default

    @Test("no arguments means serve, because that is how an MCP client launches us")
    func emptyArgumentsServe() {
        #expect(shape([]) == .serve)
    }

    // MARK: - The regression

    @Test("an unrecognised flag never falls through to serve")
    func unknownFlagDoesNotBecomeServe() {
        // The defect: `.default` returned `.serve`, so `--doctr` silently started the server.
        for argument in ["--nope", "--doctr", "--Setup", "--SETUP", "-x", "-",
                         "--", "--setup=true", "--probe=label", "serve", "setup",
                         "", " ", " --setup", "--setup ", "—setup", "/etc/passwd"] {
            let result = shape([argument])
            #expect(result != .serve, """
                \(String(reflecting: argument)) parsed as .serve. An unrecognised argument \
                must produce .unknown so the process can exit 64 instead of entering the \
                stdio server loop.
                """)
            #expect(result == .unknown(argument),
                    "\(String(reflecting: argument)) -> \(result), expected .unknown")
        }
    }

    @Test("an unknown flag is reported back verbatim, so the error message names what was typed")
    func unknownFlagIsPreservedExactly() {
        #expect(shape(["--doctr"]) == .unknown("--doctr"))
        #expect(shape(["--probe\u{0000}"]) == .unknown("--probe\u{0000}"))
        // An empty first argument is not the same thing as no arguments at all.
        #expect(shape([""]) == .unknown(""))
        #expect(shape([]) == .serve)
    }

    @Test("an unknown flag stays unknown regardless of what follows it")
    func unknownFlagIsNotRescuedByLaterArguments() {
        #expect(shape(["--nope", "--setup"]) == .unknown("--nope"))
        #expect(shape(["--nope", "--doctor", "--version"]) == .unknown("--nope"))
    }

    // MARK: - Recognised flags

    @Test("every documented flag maps to its command")
    func documentedFlagsMap() {
        #expect(shape(["--setup"]) == .setup)
        #expect(shape(["--doctor"]) == .doctor)
        #expect(shape(["--version"]) == .version)
        #expect(shape(["-v"]) == .version)
        #expect(shape(["--help"]) == .help)
        #expect(shape(["-h"]) == .help)
    }

    @Test("the pre-0.2 name --grant still performs setup")
    func grantIsAnAliasForSetup() {
        #expect(shape(["--grant"]) == .setup)
        #expect(shape(["--grant"]) == shape(["--setup"]),
                "--grant must stay behaviourally identical to --setup, not merely non-unknown")
        // --help still documents --grant in its closing paragraph; if the alias is ever
        // dropped, that text has to go with it.
        #expect(shape(["--grant"]) != .unknown("--grant"))
    }

    @Test("--grant and --setup take the same path even with trailing arguments")
    func grantAliasIgnoresTrailingArguments() {
        #expect(shape(["--grant", "extra"]) == .setup)
        #expect(shape(["--setup", "extra"]) == .setup)
    }

    // MARK: - --probe

    @Test("--probe without a label uses a fixed default rather than an empty filename")
    func probeDefaultsToManual() {
        #expect(shape(["--probe"]) == .probe("manual"))
    }

    @Test("--probe takes its label from the next argument")
    func probeUsesGivenLabel() {
        #expect(shape(["--probe", "phase1"]) == .probe("phase1"))
        #expect(shape(["--probe", ""]) == .probe(""))
        #expect(shape(["--probe", "a", "b"]) == .probe("a"), "only the first extra argument is the label")
    }

    @Test("--probe swallows a following flag as its label, which the sanitiser then has to survive")
    func probeTreatsAFollowingFlagAsALabel() {
        // Pinned rather than endorsed: `--probe --doctor` writes a probe called "--doctor"
        // instead of running the doctor. Harmless because the label is sanitised and
        // prefixed before it becomes a filename (see ProbeLabelSanitiserTests), but if that
        // is ever considered a usability bug, this test is the record of current behaviour.
        #expect(shape(["--probe", "--doctor"]) == .probe("--doctor"))
        #expect(shape(["--probe", "../../evil"]) == .probe("../../evil"))
    }

    // MARK: - Dispatch order

    @Test("only the first argument selects the command")
    func firstArgumentWins() {
        #expect(shape(["--doctor", "--setup"]) == .doctor)
        #expect(shape(["--version", "--help"]) == .version)
        #expect(shape(["--help", "--nope"]) == .help)
    }

    @Test("flag matching is exact, so near-misses fail closed instead of guessing")
    func matchingIsExactAndCaseSensitive() {
        for near in ["--setu", "--setupp", "--Setup", "--DOCTOR", "-V", "-H", "--v", "--h"] {
            #expect(shape([near]) == .unknown(near),
                    "\(near) was accepted; prefix or case-insensitive matching would let a typo grant permissions")
        }
    }
}
