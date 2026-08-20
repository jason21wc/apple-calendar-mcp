// Deciding WHICH calendars a query covers.
//
// Extracted from the EventKit adapter so it can be tested without a calendar, a permission
// grant, or a Mac with events on it. The rules are small and each one is a place where the
// obvious behaviour is wrong:
//
//   - omitted        -> every calendar. "I did not say" means "all".
//   - empty array    -> NO calendars. An explicit empty selection must not widen to
//                       everything; passing it through to EventKit's predicate would do
//                       exactly that, and silently.
//   - unknown ids    -> the ids that DO match. An identifier the user no longer has is not
//                       an error -- EventKit identifiers change on a full sync, so a stale id
//                       is an ordinary event, and failing the whole query over one would be
//                       hostile.
//   - all unknown    -> no calendars, and therefore no results. Distinguishable from "nothing
//                       scheduled" only via the resolution report below.

import Foundation

enum CalendarScope {

    /// What a request resolved to, including which ids went nowhere.
    struct Resolution: Equatable {
        /// nil means "every calendar"; an empty array means "none".
        let selectedIds: [String]?
        /// Requested ids that matched no calendar. Reported rather than swallowed, so a
        /// caller can tell a stale identifier from an empty week.
        let unmatchedIds: [String]

        var matchesNothing: Bool { selectedIds?.isEmpty == true }
    }

    static func resolve(requested: [String]?, available: [String]) -> Resolution {
        guard let requested else {
            return Resolution(selectedIds: nil, unmatchedIds: [])
        }
        let availableSet = Set(available)
        let matched = requested.filter { availableSet.contains($0) }
        let unmatched = requested.filter { !availableSet.contains($0) }
        return Resolution(selectedIds: matched, unmatchedIds: unmatched)
    }
}
