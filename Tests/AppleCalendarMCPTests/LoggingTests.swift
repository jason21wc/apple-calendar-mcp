import Testing
@testable import apple_calendar_mcp

@Suite("Diagnostic escaping")
struct LoggingTests {
    @Test("untrusted controls cannot forge lines, inject terminal commands, or truncate output")
    func controls() {
        let line = DiagnosticLog.line("one\n\r\t\u{1b}[2J\u{0}tail\u{202e}end")
        #expect(line == "[apple-calendar-mcp] one\\n\\r\\t\\u{1b}[2J\\u{0}tail\\u{202e}end\n")
        #expect(line.filter { $0 == "\n" }.count == 1)
    }

    @Test("ordinary Unicode survives, and literal escape spelling stays distinguishable")
    func ordinaryText() {
        #expect(DiagnosticLog.line("Café 📅 \\n") == "[apple-calendar-mcp] Café 📅 \\\\n\n")
    }
}
