// Text search over already-fetched events.
//
// Extracted from the tool handler for the same reason CalendarScope was extracted from the
// adapter: the rule that matters here is not "does it find the word" but "does it tell the
// truth about how much it looked at", and that is only testable away from EventKit.
//
// THE BUG THIS EXISTS TO PREVENT
// The handler used to fetch at most 500 events and then filter those, while reporting
// `total_matched` as the number of matches found and `truncated` as false whenever fewer
// than the caller's limit came back. So a search across a busy month could answer "no
// matching events" while the match sat at position 501 in start order, and a caller had no
// way to tell that answer from a real absence. Truncation must be applied AFTER matching,
// never before, or the count is a count of something the caller never asked about.

import Foundation

enum EventSearch {

    /// Which fields a query is allowed to look at. Title only, unless the caller widens it.
    static let defaultFields: Set<String> = ["title"]

    /// Case-insensitive substring match over the requested fields.
    ///
    /// Takes raw strings rather than a DTO so the adapter can match against an `EKEvent`
    /// WITHOUT converting it first. That ordering is the memory bound: a dense month is
    /// materialised by EventKit either way (`eventsMatchingPredicate` returns an array), but
    /// only the events that actually match ever become DTOs. Matching after conversion built
    /// one DTO per event in the window, including the notes and locations pulled in purely
    /// to be searched -- work thrown away for every non-match.
    ///
    /// `notes` and `location` are matched only when the caller asked to search them. They are
    /// still withheld from the RESULT unless separately requested: searching a field is not
    /// consent to disclose it.
    static func matches(title: String, notes: String?, location: String?,
                        needle: String, fields: Set<String>) -> Bool {
        if fields.contains("title"), title.lowercased().contains(needle) { return true }
        if fields.contains("notes"), let n = notes, n.lowercased().contains(needle) { return true }
        if fields.contains("location"), let l = location, l.lowercased().contains(needle) { return true }
        return false
    }

    /// Convenience for tests and for anything already holding a DTO.
    static func matches(_ event: EventDTO, needle: String, fields: Set<String>) -> Bool {
        matches(title: event.title, notes: event.notes, location: event.location,
                needle: needle, fields: fields)
    }

    /// Filter, then count, then cap -- in that order. The order is the whole point.
    ///
    /// Generic over the element so the ADAPTER runs this same function over `EKEvent`s,
    /// rather than the pure version being tested here while a separate hand-inlined copy is
    /// what actually executes. A tested function nobody calls proves nothing about the code
    /// that does the work; this project has already shipped one of those.
    ///
    /// `total` is every match, not the returned page: that difference is what separates
    /// "there are 600 of these" from "there are 100 of these", and capping before counting is
    /// what let a populated month report no matches at all.
    static func filterCountCap<T>(_ candidates: [T], limit: Int,
                                  matches isMatch: (T) -> Bool,
                                  orderedBy areInOrder: (T, T) -> Bool)
        -> (kept: [T], total: Int) {
        let matched = candidates.filter(isMatch).sorted(by: areInOrder)
        return (Array(matched.prefix(limit)), matched.count)
    }
}
