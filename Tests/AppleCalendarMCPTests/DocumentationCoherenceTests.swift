import Testing
import Foundation
@testable import apple_calendar_mcp

// Assertions against the repository's own documents.
//
// WHY THESE EXIST
// This project has now had three separate incidents of the same shape: a fact stated in
// several documents, changed in one, and left stale in the others. Phase status, the plan's
// revision number and the passing-test count each drifted independently, and the test count
// reached four different values across four files. The structural fix is to stop duplicating
// volatile facts -- these tests are what stops the duplication coming back.
//
// DELIBERATELY NARROW. This is not a documentation linter and must not grow into one. Each
// check below corresponds to a claim that was FALSE in a shipped document, is cheap to
// verify, and fails loudly with the file named. Anything requiring judgement belongs in a
// review, not here.

@Suite("Documentation coherence")
struct DocumentationCoherenceTests {

    /// Documents that describe CURRENT state and are read by users or by agents at session
    /// start. `_ai-context/PROJECT-MEMORY.md` and `LEARNING-LOG.md` are excluded on purpose:
    /// they accumulate history, and superseded claims are supposed to survive there, labelled.
    private static let currentStateDocuments = [
        "README.md", "ARCHITECTURE.md", "SPECIFICATION.md", "AGENTS.md", "CLAUDE.md",
        "docs/IMPLEMENTATION-PLAN.md", "_ai-context/SESSION-STATE.md", "_ai-context/BACKLOG.md",
        "_ai-context/OPERATIONS.md",
    ]

    private func read(_ path: String) throws -> String { try Repo.source(path) }

    @Test("the README tells a reader how to actually clone this repository")
    func readmeHasARealCloneURL() throws {
        let readme = try read("README.md")
        #expect(!readme.contains("<this repo>"),
                "the clone command still carries a placeholder; this is the first command a new user runs")
        #expect(readme.contains("github.com/jason21wc/apple-calendar-mcp"),
                "the README does not name the repository it belongs to")
    }

    @Test("no current document quotes a passing-test count")
    func noDocumentQuotesATestCount() throws {
        // The count was recorded in four places and drifted to four different numbers, none
        // checkable without running the suite that reports it. Documents point at the command.
        let pattern = try Regex(#"\d+\s+tests?\s+(pass|passing|green)"#).ignoresCase()
        for path in Self.currentStateDocuments {
            let text = try read(path)
            #expect(text.firstMatch(of: pattern) == nil, """
                \(path) quotes a test count. Say "the suite passes via ./scripts/test.sh" \
                instead -- a number here is stale the moment a test is added, and nobody \
                can check it without running the suite anyway.
                """)
        }
    }

    @Test("no current document says the read surface is still to come")
    func noDocumentSaysPhaseFourIsNext() throws {
        // Phase 4 shipped and three documents went on calling it next for two phases.
        for path in Self.currentStateDocuments {
            let text = try read(path).lowercased()
            for stale in ["phase 4 (read surface) is\n> next", "phase 4 (read surface) next",
                          "4 — read surface | **next**", "specified, not yet built"] {
                #expect(!text.contains(stale), "\(path) still describes the read surface as unbuilt")
            }
        }
    }

    @Test("only the plan states the plan's revision number")
    func onlyThePlanStatesItsRevision() throws {
        // OPERATIONS.md makes this a tripwire and the memory files were breaking it: "rev. 7"
        // was restated in two of them, which is the same shape as the test count that reached
        // four different values. The plan states its own revision; nothing else repeats it.
        let pattern = try Regex(#"rev\.\s*\d+"#).ignoresCase()
        for path in Self.currentStateDocuments where path != "docs/IMPLEMENTATION-PLAN.md" {
            let text = try read(path)
            // Historical narration is allowed -- "a stale rev. 3 copy was live" is a fact
            // about the past. What is banned is asserting the CURRENT revision, which goes
            // stale on the next revision and cannot be checked from where it is written.
            for line in text.split(separator: "\n") where line.firstMatch(of: pattern) != nil {
                let l = String(line).lowercased()
                let isHistory = l.contains("stale") || l.contains("was ") || l.contains("not restated")
                    || l.contains("deliberately no revision") || l.contains("historical")
                #expect(isHistory, """
                    \(path) states a plan revision number: "\(line.trimmingCharacters(in: .whitespaces))"
                    The plan states its own revision. A copy here is stale at rev. n+1 and                     cannot be verified from this file.
                    """)
            }
        }
    }

    @Test("no current document presents a containment control as enforced today")
    func controlsAreNotDescribedAsRunning() throws {
        // The plan's table said "Live" for C3-C7 while no mutation path exists for them to
        // gate -- a reader would have believed attendee refusal was running. It is adopted,
        // not in force. This asserts the specific wording that was wrong.
        let plan = try read("docs/IMPLEMENTATION-PLAN.md")
        for stale in ["| Live |", "| Live from Phase 5 |", "| Live, unaffected by §6 |"] {
            #expect(!plan.contains(stale),
                    "the plan's control table calls a control Live; nothing enforces it yet")
        }
        // And nothing in the shipped source mutates a calendar, which is why.
        let store = try read("Sources/apple-calendar-mcp/EventKit/CalendarStore.swift")
        for mutating in ["saveEvent", "removeEvent", "EKEvent("] {
            #expect(!store.contains(mutating), """
                CalendarStore now contains \(mutating). If a write path is being built, every                 document claiming "no write tool exists" needs revisiting in the same change.
                """)
        }
    }

    @Test("the doctor does not tell users a same-path reinstall needs re-granting")
    func doctorDistinguishesMovingFromReplacing() throws {
        // It said "Moving or reinstalling it requires running --setup again", which is wrong
        // about the second half and sends people to re-run --setup after an ordinary upgrade.
        // Measured twice, most recently across a 0.1.0 -> 0.2.0 same-path replacement: the
        // grant survived. The designated requirement is identity-based, so only the PATH
        // matters. The plan's risk table asserts --doctor "says so in plain English", which
        // makes this a claim the code has to keep true.
        let doctor = try read("Sources/apple-calendar-mcp/Diagnostics/Doctor.swift")
        #expect(!doctor.contains("Moving or reinstalling"), """
            --doctor tells users that reinstalling costs them the grant. It does not, and             this is the one message a worried user reads.
            """)
        #expect(doctor.contains("KEEPS the grant"), "the reminder no longer states what is preserved")
    }

    @Test("no current document points at a plan outside this repository")
    func theCanonicalPlanIsInTheRepo() throws {
        // The repo plan was a COPY of a private file, to be re-copied on every revision. A
        // stale rev. 3 copy was live while OPERATIONS.md named it authoritative.
        for path in Self.currentStateDocuments {
            let text = try read(path)
            #expect(!text.contains("~/.claude/plans/"), """
                \(path) treats a file outside the repository as the plan. \
                docs/IMPLEMENTATION-PLAN.md is canonical.
                """)
        }
    }

    @Test("the withdrawn allowlist survives only as labelled history")
    func noCurrentDocumentDescribesTheAllowlistAsLive() throws {
        // C1 was withdrawn 2026-08-20 and Allowlist.swift deleted. The error code outlived it
        // in the plan; the same stale-control class already shipped once, in writableReason.
        for path in Self.currentStateDocuments {
            let text = try read(path)
            #expect(!text.contains("CALENDAR_NOT_ALLOWLISTED"), """
                \(path) still lists an error code for a control that was withdrawn. A stale \
                code sends a user hunting for a config file that does not exist.
                """)
        }
        // And nothing in the shipped source refers to one at all.
        for source in ["Sources/apple-calendar-mcp/EventKit/CalendarStore.swift",
                       "Sources/apple-calendar-mcp/MCP/ToolHandlers.swift",
                       "Sources/apple-calendar-mcp/MCP/ToolRegistry.swift"] {
            #expect(!(try read(source)).contains("ALLOWLISTED"))
        }
    }

    @Test("documents that count the shipped tools agree with the registry")
    func toolCountClaimsMatchTheRegistry() throws {
        let shipped = ToolRegistry.all().count
        #expect(shipped == 5, "the tool surface changed; every document below says five")

        // The 14-tool figure is the PLANNED surface. It may be described as planned, but no
        // document may present it as what exists.
        for path in ["README.md", "ARCHITECTURE.md", "SPECIFICATION.md"] {
            let text = try read(path)
            #expect(!text.contains("## Tool surface (14)"),
                    "\(path) presents the planned surface as the shipped one")
        }

        // Every shipped tool is named by the specification, so a new tool cannot arrive
        // undocumented.
        let spec = try read("SPECIFICATION.md")
        for tool in ToolRegistry.all() {
            #expect(spec.contains(tool.name), "SPECIFICATION.md does not mention \(tool.name)")
        }
    }

    @Test("every shipped error code is documented, and no undocumented one ships")
    func errorCodesAreDocumented() throws {
        let plan = try read("docs/IMPLEMENTATION-PLAN.md")
        for code in [ToolError.permissionDenied, .badTimestamp, .badTimeZone, .endNotAfterStart,
                     .intervalTooLarge, .missingArgument, .unknownTool, .storeUnavailable] {
            #expect(plan.contains(code.rawValue), """
                \(code.rawValue) is returned by the server and appears nowhere in the plan. \
                A code is a contract; an undocumented one cannot be relied on.
                """)
        }
    }
}
