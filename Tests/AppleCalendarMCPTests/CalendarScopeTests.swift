import Testing
@testable import apple_calendar_mcp

// Answers the two questions left open by manual testing, without needing a calendar, a
// permission grant, or a machine with events on it. That is the point of extracting this:
// the rules were previously three lines inside an actor holding an EKEventStore, and so
// could only be checked by hand on a Mac with the right data.

@Suite("Calendar scoping")
struct CalendarScopeTests {

    let available = ["CAL-JASON", "CAL-FAMILY", "CAL-HOLIDAYS"]

    @Test("omitting calendar_ids searches every calendar")
    func omittedMeansAll() {
        let r = CalendarScope.resolve(requested: nil, available: available)
        #expect(r.selectedIds == nil, "nil means every calendar, not an empty selection")
        #expect(!r.matchesNothing)
        #expect(r.unmatchedIds.isEmpty)
    }

    @Test("an EMPTY calendar_ids array selects nothing — it must never widen to everything")
    func emptyMeansNone() {
        // The dangerous failure: an empty array passed through to EventKit's predicate is
        // treated as "no filter", so an explicit "search nothing" would silently search the
        // user's entire calendar set.
        let r = CalendarScope.resolve(requested: [], available: available)
        #expect(r.selectedIds == [])
        #expect(r.matchesNothing, "an explicit empty selection must match nothing")
    }

    @Test("an unknown identifier is ignored rather than failing the whole query")
    func unknownIdsAreIgnoredNotFatal() {
        // EventKit identifiers change on a full sync, so a stale id is an ordinary event, not
        // a caller error. Failing the query would punish the user for the platform's churn.
        let r = CalendarScope.resolve(requested: ["CAL-JASON", "CAL-DELETED"], available: available)
        #expect(r.selectedIds == ["CAL-JASON"])
        #expect(r.unmatchedIds == ["CAL-DELETED"])
        #expect(!r.matchesNothing, "one good id still yields a real search")
    }

    @Test("when every requested id is unknown the result is empty, and says which were unknown")
    func allUnknownReportsWhy() {
        let r = CalendarScope.resolve(requested: ["GONE-1", "GONE-2"], available: available)
        #expect(r.matchesNothing)
        // Without the unmatched list this is indistinguishable from "nothing scheduled",
        // which is the difference between a quiet week and a broken configuration.
        #expect(r.unmatchedIds == ["GONE-1", "GONE-2"])
    }

    @Test("requested order is preserved and duplicates are not silently collapsed away")
    func orderAndDuplicates() {
        let r = CalendarScope.resolve(requested: ["CAL-FAMILY", "CAL-JASON", "CAL-FAMILY"],
                                      available: available)
        #expect(r.selectedIds == ["CAL-FAMILY", "CAL-JASON", "CAL-FAMILY"])
    }

    @Test("no calendars available at all still resolves rather than crashing")
    func emptyAvailableSet() {
        #expect(CalendarScope.resolve(requested: nil, available: []).selectedIds == nil)
        let r = CalendarScope.resolve(requested: ["ANY"], available: [])
        #expect(r.matchesNothing)
        #expect(r.unmatchedIds == ["ANY"])
    }
}
