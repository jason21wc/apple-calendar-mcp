import Foundation

enum DiagnosticLog {
    /// Escape at the sink so new call sites cannot accidentally add terminal commands,
    /// forged lines, NUL truncation, or invisible direction changes to diagnostics.
    static func line(_ message: String) -> String {
        var escaped = ""
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0x5C: escaped += "\\\\"
            case 0x0A: escaped += "\\n"
            case 0x0D: escaped += "\\r"
            case 0x09: escaped += "\\t"
            default:
                if scalar.properties.generalCategory == .control
                    || scalar.properties.generalCategory == .format
                    || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    escaped += "\\u{" + String(scalar.value, radix: 16) + "}"
                } else {
                    escaped.unicodeScalars.append(scalar)
                }
            }
        }
        return "[apple-calendar-mcp] " + escaped + "\n"
    }
}

func log(_ message: String) {
    // fputs avoids FileHandle's uncatchable Objective-C exception on a broken pipe.
    // SIGPIPE is ignored at startup. stdout remains protocol-only.
    fputs(DiagnosticLog.line(message), stderr)
}
