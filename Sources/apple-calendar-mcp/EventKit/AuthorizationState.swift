// Calendar authorization state.
//
// EKAuthorizationStatus has FIVE distinct values, not six. `EKAuthorizationStatusAuthorized`
// is a deprecated alias equal to `.fullAccess` -- same raw value, runtime-indistinguishable,
// so no switch can ever separate them and any check expecting six states can never pass.
// (EKTypes.h:27-35, verified against the local SDK.)
//
// `.writeOnly` is a real state and must not be folded into `.denied`: it permits saving new
// items but not reading them, which for this server means every read fails while writes
// appear to work.

import Foundation
import EventKit

enum AuthorizationState: String, CaseIterable {
    case notDetermined
    case restricted
    case denied
    case writeOnly
    case fullAccess
    case unknown

    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted:    self = .restricted
        case .denied:        self = .denied
        case .writeOnly:     self = .writeOnly
        case .fullAccess:    self = .fullAccess
        @unknown default:    self = .unknown
        }
    }

    static var current: AuthorizationState {
        AuthorizationState(EKEventStore.authorizationStatus(for: .event))
    }

    /// Only `.fullAccess` permits fetching events. Nothing else is usable for this server.
    var canReadEvents: Bool { self == .fullAccess }

    /// What a human should do about it.
    var guidance: String {
        switch self {
        case .fullAccess:
            return "Calendar access granted."
        case .notDetermined:
            return "No decision recorded yet. Run: apple-calendar-mcp --setup"
        case .denied:
            return """
                Access was denied. Re-enable it in System Settings > Privacy & Security > \
                Calendars, or reset the decision entirely with:
                  tccutil reset Calendar \(Meta.bundleIdentifier)
                then run --setup again.
                """
        case .writeOnly:
            return """
                Write-only access. Events can be saved but NOT read, so this server cannot \
                work. Grant full access in System Settings > Privacy & Security > Calendars.
                """
        case .restricted:
            return """
                Access is restricted by a policy this user cannot change -- typically \
                parental controls or an MDM profile. Nothing this tool does can override it.
                """
        case .unknown:
            return """
                macOS reported an authorization state this build does not recognise, which \
                means a newer OS added one. Treating it as unusable. Please file an issue.
                """
        }
    }
}
