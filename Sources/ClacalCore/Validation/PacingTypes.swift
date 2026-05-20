import Foundation

enum PacingExpectationSource: String, Codable, Sendable {
    case schedule
    case empirical
}

enum PacingZoneState: String, Codable, Sendable {
    case ok
    case fast
    case slow
}

enum PacingKernelConstants {
    static let sessionMinutes: Double = 300
    static let weekMinutes: Double = 10080
    static let minActiveHoursForProjection: Double = 0.5
    static let empiricalWeeksRequired: Double = 3
    static let empiricalMinSamples = 5
    static let empiricalResetBucketWidth: TimeInterval = 3 * 3600
    static let sessionTargetInfluenceGain: Double = 0.35
    static let sessionTargetInfluenceMax: Double = 0.25
    static let sessionDeviationPositionScale: Double = 0.25
    static let sessionDeviationRateScale: Double = 0.35
    static let sessionDeviationRateWeightMax: Double = 0.15
    static let sessionDeviationDeadZone: Double = 0.05
    static let sessionDeviationHighUsageThreshold: Double = 0.9
    static let sessionDeviationHighUsageBoostMax: Double = 0.35
    static let weeklyResetTolerance: TimeInterval = 5 * 60
    static let weeklyTransientMaxPolls = 12
    static let weeklyTransientMaxDuration: TimeInterval = 2 * 3600
}

struct PacingDailyWindow: Codable, Sendable, Equatable {
    let startHour: Double
    let endHour: Double
}

struct PacingScheduleContext: Codable, Sendable, Equatable {
    let timeZoneIdentifier: String
    let dailyWindows: [PacingDailyWindow]

    init(timeZoneIdentifier: String, dailyWindows: [PacingDailyWindow]) {
        self.timeZoneIdentifier = timeZoneIdentifier
        let normalized = (dailyWindows + Array(repeating: .init(startHour: 10, endHour: 20), count: 7))
            .prefix(7)
        self.dailyWindows = Array(normalized)
    }

    init(timeZone: TimeZone, detectedWindows: [(start: Double, end: Double)]) {
        self.init(
            timeZoneIdentifier: timeZone.identifier,
            dailyWindows: detectedWindows.map { .init(startHour: $0.start, endHour: $0.end) }
        )
    }

    static func configured(timeZone: TimeZone, activeHoursPerDay: [Double]) -> Self {
        let padded = (activeHoursPerDay + Array(repeating: 10.0, count: 7)).prefix(7)
        return .init(
            timeZoneIdentifier: timeZone.identifier,
            dailyWindows: padded.map { .init(startHour: 10.0, endHour: min(10.0 + $0, 24.0)) }
        )
    }

    var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier) ?? .gmt
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}

struct PacingPollSample: Codable, Sendable, Equatable {
    let timestamp: Date
    let sessionUsage: Double
    let sessionRemaining: Double
    let weeklyUsage: Double
    let weeklyRemaining: Double
    let weeklyResetAt: Date?
}

struct PacingSessionStartSample: Codable, Sendable, Equatable {
    let timestamp: Date
    let weeklyUsage: Double
    let weeklyRemaining: Double
    let weeklyResetAt: Date?
}

struct PacingDailySnapshotSample: Codable, Sendable, Equatable {
    let date: Date
    let weeklyUsagePct: Double
    let weeklyMinsLeft: Double
}

struct PacingDailyActivitySample: Codable, Sendable, Equatable {
    let date: Date
    let activeMinutes: Double
    let idleMinutes: Double
}

struct EmpiricalExpectationDiagnostics: Codable, Sendable, Equatable {
    let sampleCount: Int
    let distinctResetBucketCount: Int
    let bucketMismatch: Bool
    let medianUsage: Double?
}

struct WeeklyDeviationBreakdown: Codable, Sendable, Equatable {
    let source: PacingExpectationSource
    let expectedUsage: Double
    let scheduleExpectedUsage: Double
    let empiricalExpectedUsage: Double?
    let empiricalDiagnostics: EmpiricalExpectationDiagnostics
    let projectedFinalUsage: Double?
    let activeElapsedHours: Double
    let activeRemainingHours: Double
    let activeTotalHours: Double
    let remainingFraction: Double
    let positionalTerm: Double
    let velocityDeviation: Double?
    let velocityWeight: Double
    let rawDeviation: Double
    let finalDeviation: Double
}

struct SessionTargetBreakdown: Codable, Sendable, Equatable {
    let weeklyDeviation: Double
    let target: Double
}

struct SessionBudgetBreakdown: Codable, Sendable, Equatable {
    let exchangeRate: Double
    let remainingActiveHours: Double
    let sessionsLeft: Double
    let budget: Double
}

struct OptimalRateBreakdown: Codable, Sendable, Equatable {
    let targetRate: Double
    let ceilingRate: Double
    let budgetRate: Double?
    let optimalRate: Double
}

struct SessionErrorBreakdown: Codable, Sendable, Equatable {
    let expectedUsage: Double
    let remainingFraction: Double
    let error: Double
}

struct SessionDeviationBreakdown: Codable, Sendable, Equatable {
    let targetInfluence: Double
    let blendedExpectedFraction: Double
    let positionScore: Double
    let rateScore: Double?
    let rateWeight: Double
    let boostedScore: Double
    let finalDeviation: Double
}

struct DailyBudgetBreakdown: Codable, Sendable, Equatable {
    let dailyDelta: Double
    let daysRemaining: Double
    let dailyAllotment: Double
    let deviation: Double
    let remainingBudgetFraction: Double
}

struct PacingCalibratorState: Codable, Sendable, Equatable {
    let zone: PacingZoneState
    let previousOutput: Double
}

struct CalibratorBreakdown: Codable, Sendable, Equatable {
    let rawBlend: Double
    let deadZoned: Double
    let hysteresisOutput: Double
    let smoothedOutput: Double
    let updatedState: PacingCalibratorState
}

struct PacingHistoryEntry: Codable, Sendable, Equatable {
    let windowEnd: Date
    let utilization: Double
}

struct PacingWeeklyWindowSegment: Codable, Sendable, Equatable {
    let resetAt: Date
    let pollCount: Int
    let duration: TimeInterval
    let maxUtilization: Double
}

struct PacingDecisionBreakdown: Codable, Sendable, Equatable {
    let weekly: WeeklyDeviationBreakdown
    let sessionTarget: SessionTargetBreakdown
    let sessionBudget: SessionBudgetBreakdown?
    let optimalRate: OptimalRateBreakdown
    let sessionError: SessionErrorBreakdown
    let sessionDeviation: SessionDeviationBreakdown
    let dailyBudget: DailyBudgetBreakdown
    let calibrator: CalibratorBreakdown
}

struct PacingOptimiserDebugState: Codable, Sendable, Equatable {
    let polls: [PacingPollSample]
    let sessionStarts: [PacingSessionStartSample]
    let dailySnapshot: PacingDailySnapshotSample?
    let dailyActivities: [PacingDailyActivitySample]
    let schedule: PacingScheduleContext
    let calibratorState: PacingCalibratorState
}

extension Poll {
    var pacingSample: PacingPollSample {
        .init(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining,
            weeklyResetAt: weeklyResetAt
        )
    }
}

extension SessionStart {
    var pacingSample: PacingSessionStartSample {
        .init(
            timestamp: timestamp,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining,
            weeklyResetAt: weeklyResetAt
        )
    }
}

extension DailySnapshot {
    var pacingSample: PacingDailySnapshotSample {
        .init(date: date, weeklyUsagePct: weeklyUsagePct, weeklyMinsLeft: weeklyMinsLeft)
    }
}

extension DailyActivity {
    var pacingSample: PacingDailyActivitySample {
        .init(date: date, activeMinutes: activeMinutes, idleMinutes: idleMinutes)
    }
}
