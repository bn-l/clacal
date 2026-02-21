import Foundation

struct UsageStats: Sendable {
    struct WeeklyEntry: Sendable, Identifiable {
        let id = UUID()
        let weekStart: Date
        let utilization: Double
    }

    struct HoursPair: Sendable {
        let active: Double
        let total: Double
    }

    let avgSessionUsage: Double?
    let hoursToday: HoursPair
    let hoursWeekAvg: HoursPair?
    let hoursAllTimeAvg: HoursPair?
    let weeklyHistory: [WeeklyEntry]
}
