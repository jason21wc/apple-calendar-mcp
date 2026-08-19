// Self-disclaiming re-exec: how this process earns its own TCC identity.
//
// THE PROBLEM (measured 2026-08-18, see PROJECT-MEMORY gotchas 19-20)
// macOS assigns TCC "responsibility" at posix_spawn time, based on the PARENT. A binary
// spawned by a terminal or an MCP client is that app's responsibility, so:
//   - the Calendar grant is recorded against the HOST app's bundle identifier
//   - our bundle identifier gets no TCC row at all
//   - we silently inherit whatever the host was granted
// Correct signing, the entitlement, hardened runtime and an embedded Info.plist are all
// necessary and none of them are sufficient. An .app wrapper does not fix it either:
// bundling only earns an independent identity when LaunchServices performs the launch, and
// an MCP client never does that because it needs stdio pipes.
//
// THE FIX
// posix_spawn ourselves once, with the private `responsibility_spawnattrs_setdisclaim`
// attribute set. A disclaimed child is its own responsible process, so TCC prompts for and
// records against OUR identity. The first process becomes a thin supervisor: the child
// inherits stdin/stdout/stderr untouched (critical -- MCP is a stdio protocol and any
// interposed pipe risks corrupting the stream), and the supervisor just waits and exits
// with the child's status.
//
// RISK, STATED PLAINLY
// `responsibility_spawnattrs_setdisclaim` is private API. It is resolved with dlsym rather
// than linked, so if Apple removes it we degrade to inherited-permission behaviour instead
// of failing to launch. `--doctor` reports which mode is in effect; never assume.

import Foundation
import Darwin

/// Child pid for the signal handlers. File-scope rather than a static member because a C
/// function pointer cannot be formed from a closure that captures context, and referencing
/// a type's static property counts as capture. `nonisolated(unsafe)` because a signal
/// handler may only touch async-signal-safe state -- a plain global that the handler reads
/// and passes to `kill` is the standard shape.
nonisolated(unsafe) private var supervisedChild: pid_t = 0

enum Reexec {

    /// Recursion guard ONLY. This is not, and cannot be, evidence of disclaim state.
    ///
    /// An earlier version bound the value to the supervisor's pid and claimed that made it
    /// unforgeable. That was wrong: every parent knows its own pid, so
    /// `APPLE_CALENDAR_MCP_DISCLAIMED=$$` defeats it in one line. Worse, the delivery path is
    /// exactly the actor the threat model names -- both Claude Code and Codex accept an
    /// `env` block in their MCP server config, and those files are same-uid writable by the
    /// coding agent this server talks to. A manipulated model could force inherited mode and
    /// the tool would still report `disclaimed-child`, which would defeat the user's
    /// revocation switch: turning off Calendar access for this binary would not stop it,
    /// because it would be using the HOST's grant instead.
    static let marker = "APPLE_CALENDAR_MCP_DISCLAIMED"

    /// Fork-bomb backstop. Also environment-controlled and therefore also untrusted, but a
    /// parent that sets it only downgrades us to inherited mode, which `isDisclaimedChild`
    /// then reports HONESTLY.
    static let depthKey = "APPLE_CALENDAR_MCP_REEXEC_DEPTH"

    /// Are we our own responsible process? Asked of the kernel, not of the environment.
    ///
    /// This consults the same subsystem the disclaim manipulates, so it is ground truth: a
    /// process that was NOT disclaimed reports its ancestor app as responsible, no matter
    /// what any environment variable claims.
    static var isDisclaimedChild: Bool {
        guard let responsible = responsibleProcess(of: getpid()) else {
            // Symbol unavailable: fall back to the environment hint, and treat the reported
            // mode as unverified rather than asserting an identity we cannot confirm.
            guard let raw = ProcessInfo.processInfo.environment[marker],
                  let claimedParent = pid_t(raw) else { return false }
            return claimedParent == getppid()
        }
        return responsible == getpid()
    }

    /// True when disclaim state was established from the kernel rather than inferred.
    static var disclaimStateIsVerified: Bool { responsibleProcess(of: getpid()) != nil }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    private static let responsibleFn: ResponsibleFn? = {
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(handle, "responsibility_get_pid_responsible_for_pid")
        else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func responsibleProcess(of pid: pid_t) -> pid_t? {
        guard let fn = responsibleFn else { return nil }
        let result = fn(pid)
        return result > 0 ? result : nil
    }

    private static var reexecDepth: Int {
        Int(ProcessInfo.processInfo.environment[depthKey] ?? "0") ?? 0
    }

    /// True when the private disclaim symbol is available on this OS.
    static var disclaimAvailable: Bool { disclaimFn != nil }

    private typealias DisclaimFn =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let disclaimFn: DisclaimFn? = {
        // RTLD_DEFAULT is (void *)-2 on Darwin.
        guard let handle = UnsafeMutableRawPointer(bitPattern: -2),
              let sym = dlsym(handle, "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(sym, to: DisclaimFn.self)
    }()

    /// Forward termination signals to the child before we die.
    ///
    /// This covers SIGTERM/SIGINT/SIGHUP. It cannot cover SIGKILL -- nothing can. The child
    /// side of that gap is Phase 2's job: the server loop MUST treat stdin EOF as
    /// unconditional shutdown, because stdin is inherited directly and so the client's pipe
    /// closure reaches the child even when the supervisor is already gone.
    private static func installSignalForwarding() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig) { received in
                if supervisedChild > 0 { kill(supervisedChild, received) }
                // Re-raise with the default disposition so our exit status is honest.
                signal(received, SIG_DFL)
                raise(received)
            }
        }
    }

    private static func selfPath() -> String {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = proc_pidpath(getpid(), &buf, UInt32(buf.count))
        guard n > 0 else { return CommandLine.arguments[0] }
        return String(decoding: buf[..<Int(n)], as: UTF8.self)
    }

    /// Re-spawn self as a disclaimed child, wait, and exit with its status.
    /// Returns only if re-exec was not possible, in which case the caller continues
    /// in inherited-permission mode.
    static func respawnDisclaimed() -> Bool {
        guard let disclaim = disclaimFn else { return false }

        // Never spawn from an already-spawned process. Independent of the marker check, so
        // a broken marker cannot produce unbounded recursion -- each level would otherwise
        // hold a live process blocked in waitpid.
        guard reexecDepth == 0 else { return false }

        var attr: posix_spawnattr_t?
        guard posix_spawnattr_init(&attr) == 0 else { return false }
        defer { posix_spawnattr_destroy(&attr) }

        guard disclaim(&attr, 1) == 0 else { return false }

        // posix_spawn propagates the calling thread's signal mask and ignored dispositions
        // across the exec. Foundation and libdispatch are already loaded by this point and
        // are known to manipulate masks; a child that starts with SIGTERM blocked is a child
        // the MCP client cannot shut down.
        var noSignalsBlocked = sigset_t()
        sigemptyset(&noSignalsBlocked)
        var allSignalsDefaulted = sigset_t()
        sigfillset(&allSignalsDefaulted)
        posix_spawnattr_setsigmask(&attr, &noSignalsBlocked)
        posix_spawnattr_setsigdefault(&attr, &allSignalsDefaulted)
        // 0x4000 is POSIX_SPAWN_CLOEXEC_DEFAULT (Darwin-only; not exposed in Swift's
        // Darwin module, hence the literal).
        let cloexecDefault: Int32 = 0x4000
        posix_spawnattr_setflags(&attr,
            Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | cloexecDefault))

        // argv, NULL-terminated
        var argv: [UnsafeMutablePointer<CChar>?] = CommandLine.arguments.map { strdup($0) }
        argv.append(nil)
        defer { for p in argv where p != nil { free(p) } }

        // envp: our environment plus the marker, NULL-terminated
        var env = ProcessInfo.processInfo.environment

        // The hardened runtime strips DYLD_* already, but that protection exists only if
        // sign.sh was actually run -- nothing in the build enforces it. Strip them here so
        // the code is safe independently of the signing step.
        for key in env.keys where key.hasPrefix("DYLD_") || key.hasPrefix("LD_")
            || key.hasPrefix("NSZombie") || key.hasPrefix("Malloc") {
            env.removeValue(forKey: key)
        }
        env[marker] = String(getpid())          // recursion hint only; never trusted as proof
        env[depthKey] = String(reexecDepth + 1)
        var envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer { for p in envp where p != nil { free(p) } }

        // Close every inherited descriptor EXCEPT stdio. Without this the child -- which is
        // about to acquire an independent Calendar identity -- inherits whatever the MCP
        // client left open without O_CLOEXEC. adddup2(fd, fd) is the documented idiom for
        // exempting a descriptor from POSIX_SPAWN_CLOEXEC_DEFAULT, so stdio still passes
        // through byte-identically and the MCP stream is untouched.
        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        for fd in Int32(0)...Int32(2) {
            posix_spawn_file_actions_adddup2(&fileActions, fd, fd)
        }
        // Installed BEFORE the spawn: a SIGTERM arriving between spawn and handler
        // installation would kill the supervisor at default disposition and orphan a
        // TCC-privileged child still holding the client's stdio. The handler no-ops while
        // supervisedChild is still 0.
        installSignalForwarding()

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, selfPath(), &fileActions, &attr, argv, envp)
        guard rc == 0 else { return false }

        supervisedChild = pid

        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(pid, &status, 0) } while reaped == -1 && errno == EINTR

        guard reaped == pid else {
            // ECHILD and friends. Reporting 0 here would claim success for a child that may
            // have crashed or may still be running -- the worst possible failure for a tool
            // whose entire output is a verdict.
            let reason = String(cString: strerror(errno))
            FileHandle.standardError.write(Data(
                "[apple-calendar-mcp] waitpid failed: \(reason)\n".utf8))
            exit(70)   // EX_SOFTWARE
        }

        if status & 0x7f == 0 {                 // exited normally
            exit((status >> 8) & 0xff)
        } else {                                // died on a signal
            exit(128 + (status & 0x7f))
        }
    }
}
