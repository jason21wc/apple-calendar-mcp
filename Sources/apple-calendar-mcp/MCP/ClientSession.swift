// What the connected client told us about itself at initialize.
//
// WHY THIS EXISTS AND WHY IT IS AN ACTOR
//
// The write surface needs to know whether this client can put a question to a human before a
// mutation. The only place that is knowable is the `initialize` handshake, where the client
// declares its capabilities -- and the SDK keeps `clientCapabilities` private, so the one way
// to see them is the hook on `Server.start`.
//
// Held in an actor rather than in `Runtime`. Runtime's values are write-once startup facts
// and use `nonisolated(unsafe)` on that basis; client state is per-connection, arrives after
// startup, and is read from tool handlers on other tasks. Adding it there would extend an
// unsafe-by-assertion pattern to data that does not satisfy the assertion.
//
// WHAT A DECLARATION IS AND IS NOT
//
// It is what the client CLAIMS. It is not evidence that a human is present, awake, or willing,
// and a capability that is declared may still fail on use. Nothing here may be treated as an
// approval, and no future write path may take "the client said it supports elicitation" as a
// substitute for actually asking and getting an answer back.

import Foundation
import MCP

/// A read-only view of the connected client, safe to put in a tool payload.
struct ClientSnapshot: Codable, Sendable, Hashable {
    /// Client-supplied, therefore untrusted text. Reported for diagnosis, never interpreted.
    let name: String?
    let version: String?
    /// The client declared the elicitation capability at all.
    let elicitationDeclared: Bool
    /// It declared FORM elicitation specifically -- the mode a confirmation would use.
    ///
    /// Checked separately because `Client.Capabilities.Elicitation` carries `form` and `url`
    /// as independent sub-capabilities: a client can declare URL-only elicitation and satisfy
    /// a top-level check while the form request it would receive is unsupported.
    let elicitationFormSupported: Bool
    let elicitationURLSupported: Bool

    enum CodingKeys: String, CodingKey {
        case name, version
        case elicitationDeclared = "elicitation_declared"
        case elicitationFormSupported = "elicitation_form_supported"
        case elicitationURLSupported = "elicitation_url_supported"
    }
}

actor ClientSession {
    static let shared = ClientSession()

    private var snapshot: ClientSnapshot?

    /// Called once from the initialize hook. Records; decides nothing.
    func record(info: Client.Info, capabilities: Client.Capabilities) {
        snapshot = ClientSnapshot(
            name: info.name,
            version: info.version,
            elicitationDeclared: capabilities.elicitation != nil,
            elicitationFormSupported: capabilities.elicitation?.form != nil,
            elicitationURLSupported: capabilities.elicitation?.url != nil)
    }

    /// Nil before initialize, or when a client sent no capabilities.
    func current() -> ClientSnapshot? { snapshot }
}
