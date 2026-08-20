import Testing
import Foundation
@testable import apple_calendar_mcp

// Calendars are where casual time handling produces confidently wrong answers, so each test
// names the property it protects rather than the function it calls.

@Suite("Time semantics")
struct TimeSemanticsTests {

    @Test("a timestamp without an offset is REJECTED, never guessed at")
    func offsetIsRequired() {
        // Resolving a bare local time against the machine's zone yields an answer that looks
        // right and is hours out for anyone in another zone -- including the user travelling.
        for bare in ["2026-09-03T14:00:00", "2026-09-03 14:00:00", "2026-09-03", "next Tuesday"] {
            #expect(throws: TimeError.self) { try TimeSemantics.parseTimestamp(bare) }
        }
    }

    @Test("offsets are honoured rather than dropped")
    func offsetsAreHonoured() throws {
        let utc = try TimeSemantics.parseTimestamp("2026-09-03T20:00:00Z")
        let denver = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00-06:00")
        #expect(utc == denver, "the same instant written two ways must parse equal")

        let a = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00-06:00")
        let b = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00-07:00")
        #expect(a != b, "same wall clock in different zones is a different instant")
    }

    @Test("fractional seconds are accepted, because clients emit them")
    func fractionalSeconds() throws {
        let plain = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00-06:00")
        let fractional = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00.000-06:00")
        #expect(abs(plain.timeIntervalSince(fractional)) < 0.001)
    }

    @Test("an end at or before the start is rejected")
    func endMustFollowStart() throws {
        let t = try TimeSemantics.parseTimestamp("2026-09-03T14:00:00Z")
        #expect(throws: TimeError.self) {
            try TimeSemantics.validateInterval(start: t, end: t, maxDays: 31)
        }
        #expect(throws: TimeError.self) {
            try TimeSemantics.validateInterval(start: t, end: t.addingTimeInterval(-3600), maxDays: 31)
        }
    }

    @Test("a window wider than the cap is refused rather than silently truncated")
    func intervalCapIsEnforced() throws {
        let start = try TimeSemantics.parseTimestamp("2026-01-01T00:00:00Z")
        // Refusing is the point: quietly returning the first 31 days of a year-long query
        // would let a caller conclude a month is free when it was never looked at.
        #expect(throws: TimeError.self) {
            try TimeSemantics.validateInterval(
                start: start, end: start.addingTimeInterval(365 * 86_400), maxDays: 31)
        }
        // Exactly at the cap is allowed.
        try TimeSemantics.validateInterval(
            start: start, end: start.addingTimeInterval(31 * 86_400), maxDays: 31)
    }

    @Test("matching is by overlap, so an event straddling the window edge is included")
    func overlapNotContainment() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let windowEnd = Date(timeIntervalSince1970: 2_000)

        // Straddles the start: a meeting already under way when the window opens.
        #expect(TimeSemantics.overlaps(eventStart: Date(timeIntervalSince1970: 500),
                                       eventEnd: Date(timeIntervalSince1970: 1_500),
                                       windowStart: windowStart, windowEnd: windowEnd))
        // Straddles the end.
        #expect(TimeSemantics.overlaps(eventStart: Date(timeIntervalSince1970: 1_500),
                                       eventEnd: Date(timeIntervalSince1970: 2_500),
                                       windowStart: windowStart, windowEnd: windowEnd))
        // Encloses the window entirely -- an all-day or multi-day event.
        #expect(TimeSemantics.overlaps(eventStart: Date(timeIntervalSince1970: 0),
                                       eventEnd: Date(timeIntervalSince1970: 9_000),
                                       windowStart: windowStart, windowEnd: windowEnd))
    }

    @Test("the interval is half-open, so an event ending exactly at the start is excluded")
    func halfOpenBoundaries() {
        let windowStart = Date(timeIntervalSince1970: 1_000)
        let windowEnd = Date(timeIntervalSince1970: 2_000)

        // Ends exactly when the window opens: not in it.
        #expect(!TimeSemantics.overlaps(eventStart: Date(timeIntervalSince1970: 500),
                                        eventEnd: windowStart,
                                        windowStart: windowStart, windowEnd: windowEnd))
        // Starts exactly when the window closes: not in it either.
        #expect(!TimeSemantics.overlaps(eventStart: windowEnd,
                                        eventEnd: Date(timeIntervalSince1970: 3_000),
                                        windowStart: windowStart, windowEnd: windowEnd))
    }

    @Test("an unknown time zone is rejected, not silently replaced with the local one")
    func badTimeZoneRejected() {
        #expect(throws: TimeError.self) { try TimeSemantics.parseTimeZone("Mars/Olympus_Mons") }
        #expect(throws: TimeError.self) { try TimeSemantics.parseTimeZone("MST7MDT_typo") }
    }

    @Test("all-day dates format as calendar dates, never as instants")
    func allDayIsDateOnly() throws {
        // The classic all-day bug is a UTC round trip moving the date across midnight, so the
        // formatter must never emit a time component at all.
        let instant = try TimeSemantics.parseTimestamp("2026-09-03T00:00:00-06:00")
        let denver = try TimeSemantics.parseTimeZone("America/Denver")
        let formatted = TimeSemantics.formatAllDay(instant, in: denver)
        #expect(formatted == "2026-09-03")
        #expect(!formatted.contains("T"))
        #expect(!formatted.contains(":"))
    }

    @Test("a limit above the hard cap is clamped rather than honoured")
    func limitsAreClamped() {
        #expect(Limits.clampResultLimit(nil) == Limits.defaultResultLimit)
        #expect(Limits.clampResultLimit(10) == 10)
        #expect(Limits.clampResultLimit(100_000) == Limits.maxResultLimit)
        #expect(Limits.clampResultLimit(0) == 1, "zero would return nothing and read as empty")
        #expect(Limits.clampResultLimit(-5) == 1)
    }
}
