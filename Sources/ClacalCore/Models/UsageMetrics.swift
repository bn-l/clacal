import Foundation

public struct UsageMetrics: Sendable {
    public let sessionUsagePct: Double
    public let weeklyUsagePct: Double
    public let sessionMinsLeft: Double
    public let weeklyMinsLeft: Double
    public let calibrator: Double
    public let sessionTarget: Double
    public let sessionDeviation: Double
    public let dailyDeviation: Double
    public let dailyBudgetRemaining: Double
    public let weeklyDeviation: Double
    public let sessionElapsedPct: Double
    public let weeklyElapsedPct: Double
    public let isSessionActive: Bool
    public let timestamp: Date
}
