import Testing
import Foundation
@testable import apple_calendar_mcp

// Shutdown and orphan behaviour of the real server process.
//
// WHY THIS COULD NOT BE WRITTEN BEFORE
// The plan carried "orphan behaviour verified" as an exit criterion through three phases and
// it was never met, for a concrete reason: every subprocess test invoked --version or --help,
// which exits in milliseconds, so there was no live child to observe and the check would have
// been inconclusive rather than passing. `serve` is the first command that stays up.
//
// WHAT IS AT STAKE
// The supervisor re-spawns itself disclaimed and blocks in waitpid; the CHILD is the process
// holding the Calendar grant and the client's stdout pipe. If the supervisor dies and the
// child does not, the client believes the server is gone while a Calendar-authorized process
// keeps running against a pipe nobody reads. SIGTERM is covered by signal forwarding; SIGKILL
// cannot be, and stdin EOF is the only thing that covers it.
//
// SAFETY
// `serve` reads no calendar data and requests no permission -- it constructs an EKEventStore
// and reads the authorization STATUS, neither of which prompts. It also writes nothing: the
// state directory is created by --probe and by the journal, not by the server loop. No
// tools/call is ever issued here, so nothing queries the user's calendar.

@Suite("Server lifecycle")
struct ServerLifecycleTests {

    /// A running `serve` process plus the write end of its stdin.
    private struct Server {
        let task: Process
        let stdinWriter: FileHandle
        var supervisorPid: Int32 { task.processIdentifier }
    }

    private func launch() throws -> Server {
        let task = Process()
        task.executableURL = try Repo.builtExecutable()
        // NO ARGUMENTS. Serving is the argless default -- there is no `serve` subcommand,
        // and passing one exits EX_USAGE as an unknown flag. Verified the hard way here.
        task.arguments = []
        // Explicit, never inherited: an exported disclaim marker from the developer's shell
        // would otherwise decide whether a child is spawned at all.
        task.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]

        let input = Pipe()
        task.standardInput = input
        // Null rather than a pipe nobody drains: the server logs to stderr at startup, and a
        // full pipe buffer would block it in write() and make every timing assertion below a
        // measurement of the test harness instead of the server.
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        try task.run()
        return Server(task: task, stdinWriter: input.fileHandleForWriting)
    }

    /// Direct children of `pid`, via pgrep. The disclaimed child is the process that matters.
    private func children(of pid: Int32) throws -> [Int32] {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-P", String(pid)]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = FileHandle.nullDevice
        try task.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard task.terminationStatus == 0 || task.terminationStatus == 1 else {
            throw LifecycleError.processInspectionUnavailable
        }
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func isAlive(_ pid: Int32) -> Bool {
        // Signal 0 tests for existence without delivering anything. ESRCH means gone; EPERM
        // would mean alive but not ours, which cannot happen for our own child.
        kill(pid, 0) == 0 || errno == EPERM
    }

    @discardableResult
    private func waitUntil(_ deadline: TimeInterval = 10,
                           _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            if condition() { return true }
            usleep(20_000)
        }
        return condition()
    }

    /// Launch, and wait until the disclaimed child exists so the test observes a real
    /// supervisor/child pair rather than racing startup.
    private func launchAndSettle() throws -> (Server, Int32) {
        let server = try launch()
        var child: Int32 = 0
        var settled = false
        defer {
            if !settled { cleanUp(server, child) }
        }
        let deadline = Date().addingTimeInterval(10)
        repeat {
            child = try children(of: server.supervisorPid).first ?? 0
            if child != 0 { break }
            usleep(20_000)
        } while Date() < deadline
        let appeared = child != 0
        try #require(appeared, """
            no child appeared under the supervisor within the deadline. Either the \
            self-disclaiming re-exec did not fire -- in which case the process is running \
            under the launching app's Calendar identity -- or the binary failed to start.
            """)
        settled = true
        return (server, child)
    }

    private func cleanUp(_ server: Server, _ child: Int32) {
        // Never leave a Calendar-authorized process behind, whatever the test concluded.
        // PID zero targets the whole process group; it is never a child to clean up.
        if child > 0 && isAlive(child) { kill(child, SIGKILL) }
        if server.task.isRunning { server.task.terminate() }
        try? server.stdinWriter.close()
        _ = waitUntil(5) { !server.task.isRunning }
    }

    @Test("closing stdin shuts the server down, supervisor and child both")
    func stdinEofShutsDown() throws {
        let (server, child) = try launchAndSettle()
        defer { cleanUp(server, child) }

        try server.stdinWriter.close()

        #expect(waitUntil { !server.task.isRunning }, """
            the supervisor was still running after stdin closed. stdin EOF is unconditional \
            shutdown -- without it a killed client leaves this process alive.
            """)
        #expect(waitUntil { !isAlive(child) }, """
            the disclaimed child outlived stdin EOF. It is the process holding the Calendar \
            grant and the client's stdout pipe.
            """)
    }

    @Test("SIGTERM to the supervisor takes the child with it")
    func sigtermLeavesNoOrphan() throws {
        let (server, child) = try launchAndSettle()
        defer { cleanUp(server, child) }

        // The supervisor installs handlers for SIGTERM/SIGINT/SIGHUP and forwards them.
        kill(server.supervisorPid, SIGTERM)

        #expect(waitUntil { !server.task.isRunning }, "the supervisor ignored SIGTERM")
        #expect(waitUntil { !isAlive(child) }, """
            SIGTERM killed the supervisor and left the child running -- a Calendar-authorized \
            orphan the client believes is dead. Signal forwarding in Reexec is not working.
            """)
    }

    @Test("SIGKILL cannot be forwarded, so stdin EOF is what reaps the child")
    func sigkillIsCoveredByEof() throws {
        let (server, child) = try launchAndSettle()
        defer { cleanUp(server, child) }

        // Nothing can handle SIGKILL, so the supervisor dies without forwarding anything.
        // The child survives this moment by design -- and that is precisely the case stdin
        // EOF exists to cover, because the client's pipe is inherited by the child directly.
        kill(server.supervisorPid, SIGKILL)
        #expect(waitUntil { !server.task.isRunning }, "the supervisor survived SIGKILL")

        try server.stdinWriter.close()

        #expect(waitUntil { !isAlive(child) }, """
            the child outlived both its supervisor and the closing of stdin. This is the \
            unrecoverable case: no signal handler can cover SIGKILL, so if EOF does not \
            shut the child down, nothing does.
            """)
    }
}

private enum LifecycleError: Error, CustomStringConvertible {
    case processInspectionUnavailable
    var description: String {
        "pgrep cannot inspect the test server's children in this environment; "
        + "run the lifecycle suite in an environment with process-inspection permission"
    }
}
