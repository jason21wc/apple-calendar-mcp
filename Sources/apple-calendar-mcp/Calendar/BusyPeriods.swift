import Foundation

/// Pure merging logic shared by the adapter and synthetic tests. No Calendar access.
enum BusyPeriods {
    static func merge(_ periods: [DateInterval], zone: TimeZone) -> [BusyInterval] {
        var merged: [(start: Date, end: Date, count: Int)] = []
        for p in periods.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, p.start <= last.end {
                merged[merged.count - 1] = (last.start, max(last.end, p.end), last.count + 1)
            } else {
                merged.append((p.start, p.end, 1))
            }
        }
        return merged.map {
            BusyInterval(start: TimeSemantics.format($0.start, in: zone),
                         end: TimeSemantics.format($0.end, in: zone), eventCount: $0.count)
        }
    }
}
