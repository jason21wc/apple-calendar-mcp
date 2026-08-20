// Query bounds.
//
// These are not performance tuning. An unbounded calendar query returns a decade of events
// into a model's context, and a truncated one that does not SAY it was truncated is worse:
// the model concludes the afternoon is free because the answer stopped early.

import Foundation

enum Limits {
    /// Returned when the caller does not ask.
    static let defaultResultLimit = 100

    /// Hard ceiling regardless of what the caller asks for.
    static let maxResultLimit = 500

    /// Longest window a single query may cover. EventKit's own predicate caps at four years;
    /// this is far tighter, because a month is the honest granularity for "what's coming up"
    /// and anything wider should be several deliberate queries.
    static let maxIntervalDays = 31

    static func clampResultLimit(_ requested: Int?) -> Int {
        guard let requested else { return defaultResultLimit }
        return max(1, min(requested, maxResultLimit))
    }

    static var applied: LimitsApplied {
        LimitsApplied(limit: maxResultLimit, maxIntervalDays: maxIntervalDays)
    }
}
