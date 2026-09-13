import Testing
import Foundation
import EventKit
@testable import apple_calendar_mcp

@Suite("Busy classification and merging")
struct BusyPeriodsTests {
    @Test("unsupported availability stays busy; only explicit free or cancellation excludes")
    func unknownIsNotFree() {
        for status: EKEventStatus in [.none, .confirmed, .tentative] {
            for availability: EKEventAvailability in [.notSupported, .busy, .tentative, .unavailable] {
                #expect(CalendarStore.countsAsBusy(status: status, availability: availability))
            }
            #expect(!CalendarStore.countsAsBusy(status: status, availability: .free))
        }
        #expect(!CalendarStore.countsAsBusy(status: .canceled, availability: .notSupported))
        #expect(!CalendarStore.countsAsBusy(status: .canceled, availability: .busy))
    }

    @Test("overlapping and touching periods merge with the actual contributing count")
    func merging() throws {
        let base = try TimeSemantics.parseTimestamp("2026-09-13T08:00:00Z")
        let ranges = [(60.0, 120.0), (0.0, 90.0), (120.0, 180.0), (240.0, 300.0)]
        let merged = BusyPeriods.merge(ranges.map {
            DateInterval(start: base.addingTimeInterval($0.0), end: base.addingTimeInterval($0.1))
        }, zone: .gmt)
        #expect(merged.count == 2)
        #expect(merged.first?.eventCount == 3)
        #expect(merged.first?.start == TimeSemantics.format(base, in: .gmt))
        #expect(merged.first?.end == TimeSemantics.format(base.addingTimeInterval(180), in: .gmt))
        #expect(BusyPeriods.merge([], zone: .gmt).isEmpty)
    }
}
