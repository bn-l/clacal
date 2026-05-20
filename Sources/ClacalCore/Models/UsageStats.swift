import Foundation

public struct UsageStats: Sendable {
    public struct WeeklyEntry: Sendable, Identifiable {
        public let id = UUID()
        public let windowEnd: Date
        public let utilization: Double
    }

    public struct HoursPair: Sendable {
        public let active: Double
        public let total: Double
    }

    public let avgSessionUsage: Double?
    public let hoursToday: HoursPair
    public let hoursWeekAvg: HoursPair?
    public let hoursAllTimeAvg: HoursPair?
    public let weeklyHistory: [WeeklyEntry]
}
