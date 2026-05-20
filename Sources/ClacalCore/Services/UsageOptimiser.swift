import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "Optimiser")

struct OptimiserResult: Sendable {
    let calibrator: Double
    let target: Double
    let optimalRate: Double
    let currentRate: Double?
    let weeklyDeviation: Double
    let exchangeRate: Double?
    let sessionBudget: Double?
    let isNewSession: Bool
    let sessionDeviation: Double
    let dailyDeviation: Double
    let dailyBudgetRemaining: Double
}

@MainActor
final class UsageOptimiser {
    static let sessionMinutes = PacingKernelConstants.sessionMinutes
    static let weekMinutes = PacingKernelConstants.weekMinutes

    private static let maxDays = 90
    private static let emaAlpha = 0.3
    private static let gapThresholdMinutes: Double = 15
    private static let boundaryJumpMinutes: Double = 30
    private static let minExchangeRateSamples = 10
    private static let windowDetectionMinPolls = 3
    private static let windowDetectionDaysRequired: Double = 7

    private static let dayResetHour = 5 // 5am local time
    private static let idleGraceMinutes: Double = 30
    private static let maxActivityDays = 365

    private(set) var polls: [Poll]
    private(set) var sessionStarts: [SessionStart]
    private(set) var dailySnapshot: DailySnapshot?
    private(set) var dailyActivities: [DailyActivity]
    private(set) var lastDecisionBreakdown: PacingDecisionBreakdown?
    private var detectedWindows: [(start: Double, end: Double)]
    private let persistURL: URL?
    private let timeZone: TimeZone
    private var pacingZone: PacingZoneState = .ok
    private var prevCalOutput: Double = 0

    // Idle tracking state
    private var lastUsageGrowth: Date?
    private var pendingGraceMinutes: Double = 0

    init(
        data: StoreData = StoreData(),
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        persistURL: URL? = nil,
        timeZone: TimeZone = .current,
        detectedWindows: [(start: Double, end: Double)]? = nil
    ) {
        self.polls = data.polls
        self.sessionStarts = data.sessions
        self.dailySnapshot = data.dailySnapshot
        self.dailyActivities = data.dailyActivities
        self.persistURL = persistURL
        self.timeZone = timeZone
        let normalizedSchedule: PacingScheduleContext = if let detectedWindows {
            PacingScheduleContext(
                timeZoneIdentifier: timeZone.identifier,
                dailyWindows: detectedWindows.map { PacingDailyWindow(startHour: $0.start, endHour: $0.end) }
            )
        } else {
            PacingScheduleContext.configured(
                timeZone: timeZone,
                activeHoursPerDay: activeHoursPerDay
            )
        }
        self.detectedWindows = normalizedSchedule.dailyWindows.map { (start: $0.startHour, end: $0.endHour) }

        // Derive lastUsageGrowth from existing polls
        for i in stride(from: polls.count - 1, through: 1, by: -1) {
            if polls[i].sessionUsage > polls[i - 1].sessionUsage {
                lastUsageGrowth = polls[i].timestamp
                break
            }
        }

        logger.info("Optimiser init: polls=\(data.polls.count, privacy: .public) sessions=\(data.sessions.count, privacy: .public) activities=\(data.dailyActivities.count, privacy: .public) persist=\(persistURL != nil, privacy: .public)")
    }

    // MARK: - Public API

    func recordPoll(
        sessionUsage: Double,
        sessionRemaining: Double,
        weeklyUsage: Double,
        weeklyRemaining: Double,
        weeklyResetAt: Date? = nil,
        timestamp: Date = Date()
    ) -> OptimiserResult {
        let poll = Poll(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining,
            weeklyResetAt: weeklyResetAt
        )

        let isNewSession = detectSessionBoundary(poll)
        if isNewSession {
            sessionStarts.append(SessionStart(
                timestamp: timestamp,
                weeklyUsage: weeklyUsage,
                weeklyRemaining: weeklyRemaining,
                weeklyResetAt: weeklyResetAt
            ))
            pacingZone = .ok
            prevCalOutput = 0
            logger.info("New session detected at \(timestamp, privacy: .public) weeklyUsage=\(weeklyUsage, privacy: .public)")
        }

        polls.append(poll)
        trackActivity(poll, isNewSession: isNewSession)
        pruneOldRecords()
        maybeUpdateDetectedWindows(referenceDate: poll.timestamp)
        maybeUpdateDailySnapshot(poll)

        let velocity = sessionVelocity()
        let decision = decisionBreakdown(for: poll, currentRate: velocity)
        pacingZone = decision.calibrator.updatedState.zone
        prevCalOutput = decision.calibrator.updatedState.previousOutput
        lastDecisionBreakdown = decision

        persist()

        logger.info("Poll recorded: calibrator=\(decision.calibrator.smoothedOutput, privacy: .public) target=\(decision.sessionTarget.target, privacy: .public) optimalRate=\(decision.optimalRate.optimalRate, privacy: .public) weeklyDev=\(decision.weekly.finalDeviation, privacy: .public) sessionDev=\(decision.sessionDeviation.finalDeviation, privacy: .public) dailyDev=\(decision.dailyBudget.deviation, privacy: .public) dailyRemaining=\(decision.dailyBudget.remainingBudgetFraction, privacy: .public) newSession=\(isNewSession, privacy: .public)")

        return OptimiserResult(
            calibrator: decision.calibrator.smoothedOutput,
            target: decision.sessionTarget.target,
            optimalRate: decision.optimalRate.optimalRate,
            currentRate: velocity,
            weeklyDeviation: decision.weekly.finalDeviation,
            exchangeRate: decision.sessionBudget?.exchangeRate,
            sessionBudget: decision.sessionBudget?.budget,
            isNewSession: isNewSession,
            sessionDeviation: decision.sessionDeviation.finalDeviation,
            dailyDeviation: decision.dailyBudget.deviation,
            dailyBudgetRemaining: decision.dailyBudget.remainingBudgetFraction
        )
    }

    // MARK: - Session Boundary Detection

    private func detectSessionBoundary(_ poll: Poll) -> Bool {
        guard let previous = polls.last else {
            return true // Bootstrap: first poll ever
        }

        let timerJumped = poll.sessionRemaining - previous.sessionRemaining > Self.boundaryJumpMinutes
        let wallClockMinutes = poll.timestamp.timeIntervalSince(previous.timestamp) / 60
        let sessionExpired = previous.sessionRemaining > 0 && wallClockMinutes > previous.sessionRemaining

        return timerJumped || sessionExpired
    }

    private var currentSessionStartTimestamp: Date? {
        sessionStarts.last?.timestamp
    }

    func debugState() -> PacingOptimiserDebugState {
        .init(
            polls: polls.map(\.pacingSample),
            sessionStarts: sessionStarts.map(\.pacingSample),
            dailySnapshot: dailySnapshot?.pacingSample,
            dailyActivities: dailyActivities.map(\.pacingSample),
            schedule: scheduleContext(),
            calibratorState: currentCalibratorState()
        )
    }

    func computeStats(now: Date) -> UsageStats {
        computeStats(referenceDate: now)
    }

    private func scheduleContext() -> PacingScheduleContext {
        .init(timeZone: timeZone, detectedWindows: detectedWindows)
    }

    private func calendar() -> Calendar {
        scheduleContext().calendar
    }

    private func currentCalibratorState() -> PacingCalibratorState {
        .init(zone: pacingZone, previousOutput: prevCalOutput)
    }

    private func decisionBreakdown(for poll: Poll, currentRate: Double?) -> PacingDecisionBreakdown {
        let pollSample = poll.pacingSample
        let schedule = scheduleContext()
        let weekly = PacingKernel.weeklyBreakdown(
            current: pollSample,
            history: Array(polls.dropLast().map(\.pacingSample)),
            schedule: schedule,
            dataWeeks: dataWeeks()
        )
        let sessionTarget = PacingKernel.sessionTarget(for: weekly.finalDeviation)
        let remainingActiveHours = PacingKernel.activeHoursInRange(
            from: poll.timestamp,
            to: poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60),
            schedule: schedule
        )
        let budget = PacingKernel.sessionBudget(
            current: pollSample,
            exchangeRate: exchangeRate(),
            remainingActiveHours: remainingActiveHours
        )
        let optimalRate = PacingKernel.optimalRate(
            current: pollSample,
            target: sessionTarget.target,
            sessionBudget: budget
        )
        let sessionError = PacingKernel.sessionError(
            current: pollSample,
            target: sessionTarget.target
        )
        let sessionDeviation = PacingKernel.sessionDeviation(
            current: pollSample,
            target: sessionTarget.target,
            optimalRate: optimalRate.optimalRate,
            currentRate: currentRate
        )
        let dailyBudget = PacingKernel.dailyBudget(
            current: pollSample,
            snapshot: dailySnapshot?.pacingSample
        )
        let calibrator = PacingKernel.calibrator(
            previousState: currentCalibratorState(),
            sessionError: sessionError.error,
            weeklyDeviation: weekly.finalDeviation,
            current: pollSample
        )

        return .init(
            weekly: weekly,
            sessionTarget: sessionTarget,
            sessionBudget: budget,
            optimalRate: optimalRate,
            sessionError: sessionError,
            sessionDeviation: sessionDeviation,
            dailyBudget: dailyBudget,
            calibrator: calibrator
        )
    }

    // MARK: - Velocity Estimation

    private func sessionVelocity() -> Double? {
        guard let sessionStart = currentSessionStartTimestamp else { return nil }
        let sessionPolls = polls.filter { $0.timestamp >= sessionStart }
        return emaVelocity(sessionPolls) { $0.sessionUsage }
    }

    private func emaVelocity(_ points: [Poll], value: (Poll) -> Double) -> Double? {
        guard points.count >= 2 else { return nil }
        var ema: Double?
        for index in 1..<points.count {
            let deltaMinutes = points[index].timestamp.timeIntervalSince(points[index - 1].timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { continue }
            let instantVelocity = (value(points[index]) - value(points[index - 1])) / deltaMinutes
            ema = ema.map { Self.emaAlpha * instantVelocity + (1 - Self.emaAlpha) * $0 } ?? instantVelocity
        }
        return ema
    }

    // MARK: - Exchange Rate

    func exchangeRate() -> Double? {
        var ratios: [Double] = []
        forEachPollPairWithinSession { previous, current in
            let deltaMinutes = current.timestamp.timeIntervalSince(previous.timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { return }
            let deltaSession = current.sessionUsage - previous.sessionUsage
            let deltaWeekly = current.weeklyUsage - previous.weeklyUsage
            if deltaSession > 0.5 {
                ratios.append(deltaWeekly / deltaSession)
            }
        }
        guard ratios.count >= Self.minExchangeRateSamples else { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    // Session starts and polls are chronological. Walk them once together so a
    // single poll update doesn't repeatedly rescan the full session history.
    private func forEachPollPairWithinSession(_ body: (Poll, Poll) -> Void) {
        guard polls.count >= 2 else { return }

        var nextSessionStartIndex = sessionStarts.firstIndex {
            $0.timestamp > polls[0].timestamp
        } ?? sessionStarts.endIndex

        for index in 1..<polls.count {
            let previous = polls[index - 1]
            let current = polls[index]
            let crossesBoundary = nextSessionStartIndex < sessionStarts.endIndex
                && sessionStarts[nextSessionStartIndex].timestamp <= current.timestamp

            if !crossesBoundary {
                body(previous, current)
            }

            while nextSessionStartIndex < sessionStarts.endIndex,
                  sessionStarts[nextSessionStartIndex].timestamp <= current.timestamp {
                nextSessionStartIndex += 1
            }
        }
    }

    // MARK: - Active Hours Schedule

    func activeHoursInRange(from start: Date, to end: Date) -> Double {
        PacingKernel.activeHoursInRange(from: start, to: end, schedule: scheduleContext())
    }

    // MARK: - Window Auto-Detection

    private func maybeUpdateDetectedWindows(referenceDate: Date) {
        guard let firstPoll = polls.first else { return }
        let daysSinceFirst = referenceDate.timeIntervalSince(firstPoll.timestamp) / 86400
        guard daysSinceFirst >= Self.windowDetectionDaysRequired else { return }

        let calendar = calendar()
        var activeHoursByDay = Array(repeating: [Double](), count: 7)

        forEachPollPairWithinSession { previous, current in
            let deltaSession = current.sessionUsage - previous.sessionUsage
            guard deltaSession > 0.5 else { return }

            let calendarWeekday = calendar.component(.weekday, from: current.timestamp)
            let dayIndex = (calendarWeekday + 5) % 7
            let hour = Double(calendar.component(.hour, from: current.timestamp))
                + Double(calendar.component(.minute, from: current.timestamp)) / 60
            activeHoursByDay[dayIndex].append(hour)
        }

        for dayIndex in 0..<7 {
            let activeHours = activeHoursByDay[dayIndex]
            guard activeHours.count >= Self.windowDetectionMinPolls else { continue }

            let earliest = activeHours.min()!
            let latest = activeHours.max()!
            // Pad 1h on each side, clamped to 0–24
            let detectedStart = max(0, earliest - 1)
            let detectedEnd = min(24, latest + 1)

            if detectedEnd - detectedStart >= 2 {
                detectedWindows[dayIndex] = (start: detectedStart, end: detectedEnd)
            }
        }
    }

    // MARK: - Daily Snapshot & Ratios

    private func maybeUpdateDailySnapshot(_ poll: Poll) {
        let calendar = calendar()
        let boundary = dayBoundary(for: poll.timestamp, calendar: calendar)

        if let existing = dailySnapshot {
            let existingBoundary = dayBoundary(for: existing.date, calendar: calendar)
            let weeklyReset = polls.count >= 2
                && didWeeklyReset(from: polls[polls.count - 2], to: poll)
            guard boundary > existingBoundary || weeklyReset else { return }
        }

        dailySnapshot = DailySnapshot(
            date: poll.timestamp,
            weeklyUsagePct: poll.weeklyUsage,
            weeklyMinsLeft: poll.weeklyRemaining
        )
        logger.info("Daily snapshot captured: weeklyUsage=\(poll.weeklyUsage, privacy: .public) weeklyMinsLeft=\(poll.weeklyRemaining, privacy: .public)")
    }

    private func dayBoundary(for date: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: date)
        let startOfDay = calendar.startOfDay(for: date)
        let boundary = startOfDay.addingTimeInterval(Double(Self.dayResetHour) * 3600)
        return hour < Self.dayResetHour
            ? boundary.addingTimeInterval(-86400)
            : boundary
    }

    private func weekStart(for poll: Poll) -> Date {
        PacingKernel.resolvedWeeklyResetAt(for: poll.pacingSample)
            .addingTimeInterval(-Self.weekMinutes * 60)
    }

    private func isTransientWeeklySegment(_ segment: PacingWeeklyWindowSegment) -> Bool {
        segment.pollCount <= PacingKernelConstants.weeklyTransientMaxPolls
            && segment.duration <= PacingKernelConstants.weeklyTransientMaxDuration
    }

    private func didWeeklyReset(from previous: Poll, to current: Poll) -> Bool {
        PacingKernel.didWeeklyReset(previous: previous.pacingSample, current: current.pacingSample)
    }

    private func weeklyWindowSegments() -> [PacingWeeklyWindowSegment] {
        PacingKernel.weeklyWindowSegments(polls: polls.map(\.pacingSample))
    }

    // MARK: - Idle Tracking

    private func trackActivity(_ poll: Poll, isNewSession: Bool) {
        let calendar = calendar()

        // Reset on new session — commit pending as idle
        if isNewSession {
            if pendingGraceMinutes > 0 {
                accumulateActivity(idleMinutes: pendingGraceMinutes, at: poll.timestamp, calendar: calendar)
                pendingGraceMinutes = 0
            }
            lastUsageGrowth = nil
            return
        }

        // Need at least 2 polls for interval tracking
        guard polls.count >= 2 else { return }
        let prevPoll = polls[polls.count - 2]

        // Skip large gaps (app wasn't running)
        let deltaMinutes = poll.timestamp.timeIntervalSince(prevPoll.timestamp) / 60
        guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else {
            if pendingGraceMinutes > 0 {
                accumulateActivity(idleMinutes: pendingGraceMinutes, at: poll.timestamp, calendar: calendar)
                pendingGraceMinutes = 0
            }
            lastUsageGrowth = nil
            return
        }

        let usageGrew = poll.sessionUsage > prevPoll.sessionUsage

        if usageGrew {
            // Growth resumed — pending grace minutes were active after all
            accumulateActivity(activeMinutes: pendingGraceMinutes + deltaMinutes, at: poll.timestamp, calendar: calendar)
            pendingGraceMinutes = 0
            lastUsageGrowth = poll.timestamp
        } else if let lastGrowth = lastUsageGrowth,
                  poll.timestamp.timeIntervalSince(lastGrowth) / 60 < Self.idleGraceMinutes {
            // Within grace period — buffer as uncertain
            pendingGraceMinutes += deltaMinutes
        } else {
            // Grace expired or no prior growth — all pending + this interval is idle
            accumulateActivity(idleMinutes: pendingGraceMinutes + deltaMinutes, at: poll.timestamp, calendar: calendar)
            pendingGraceMinutes = 0
            lastUsageGrowth = nil
        }
    }

    private func accumulateActivity(activeMinutes: Double = 0, idleMinutes: Double = 0, at date: Date, calendar: Calendar) {
        let boundary = dayBoundary(for: date, calendar: calendar)

        if let index = dailyActivities.firstIndex(where: { dayBoundary(for: $0.date, calendar: calendar) == boundary }) {
            dailyActivities[index].activeMinutes += activeMinutes
            dailyActivities[index].idleMinutes += idleMinutes
        } else {
            dailyActivities.append(DailyActivity(
                date: boundary,
                activeMinutes: activeMinutes,
                idleMinutes: idleMinutes
            ))
        }
    }

    // MARK: - Stats

    func computeStats() -> UsageStats {
        computeStats(referenceDate: Date())
    }

    private func computeStats(referenceDate now: Date) -> UsageStats {
        let calendar = calendar()
        let todayBound = dayBoundary(for: now, calendar: calendar)
        let weeklySegments = weeklyWindowSegments()

        // Avg session usage — peak usage of each *completed* session
        var sessionPeaks: [Double] = []
        let completedCount = max(sessionStarts.count - 1, 0)
        for i in 0..<completedCount {
            let start = sessionStarts[i].timestamp
            let nextStart = sessionStarts[i + 1].timestamp
            let peak = polls
                .filter { $0.timestamp >= start && $0.timestamp < nextStart }
                .map(\.sessionUsage)
                .max()
            if let peak, peak > 0 { sessionPeaks.append(peak) }
        }
        let avgSessionUsage = sessionPeaks.isEmpty
            ? nil
            : sessionPeaks.reduce(0, +) / Double(sessionPeaks.count)

        // Hours from daily activities
        let todayEntry = dailyActivities.first { dayBoundary(for: $0.date, calendar: calendar) == todayBound }
        let hoursToday = UsageStats.HoursPair(
            active: (todayEntry?.activeMinutes ?? 0) / 60,
            total: ((todayEntry?.activeMinutes ?? 0) + (todayEntry?.idleMinutes ?? 0)) / 60
        )

        // Week average per day
        let hoursWeekAvg: UsageStats.HoursPair?
        let currentWeekStart: Date?
        if let currentSegment = weeklySegments.last,
           currentSegment.resetAt > now,
           !isTransientWeeklySegment(currentSegment) {
            currentWeekStart = currentSegment.resetAt.addingTimeInterval(-Self.weekMinutes * 60)
        } else {
            currentWeekStart = polls.last.map(weekStart(for:))
        }
        if let weekStart = currentWeekStart {
            let daysThisWeek = max(now.timeIntervalSince(weekStart) / 86400.0, 1.0)
            let weekEntries = dailyActivities.filter { $0.date >= weekStart }
            let weekActive = weekEntries.reduce(0.0) { $0 + $1.activeMinutes } / 60
            let weekTotal = weekEntries.reduce(0.0) { $0 + $1.activeMinutes + $1.idleMinutes } / 60
            hoursWeekAvg = .init(active: weekActive / daysThisWeek, total: weekTotal / daysThisWeek)
        } else {
            hoursWeekAvg = nil
        }

        // All-time average per day
        let hoursAllTimeAvg: UsageStats.HoursPair?
        if let first = dailyActivities.first {
            let totalDays = max(now.timeIntervalSince(first.date) / 86400, 1)
            let allActive = dailyActivities.reduce(0.0) { $0 + $1.activeMinutes } / 60
            let allTotal = dailyActivities.reduce(0.0) { $0 + $1.activeMinutes + $1.idleMinutes } / 60
            hoursAllTimeAvg = .init(active: allActive / totalDays, total: allTotal / totalDays)
        } else {
            hoursAllTimeAvg = nil
        }

        // Weekly utilization history — use stable reset windows and show completed windows only.
        var weeklyHistory = PacingKernel.weeklyHistory(
            polls: polls.map(\.pacingSample),
            now: now
        )
            .map { UsageStats.WeeklyEntry(windowEnd: $0.windowEnd, utilization: $0.utilization) }
            .sorted { $0.windowEnd > $1.windowEnd }
        if weeklyHistory.count > 6 { weeklyHistory = Array(weeklyHistory.prefix(6)) }

        return UsageStats(
            avgSessionUsage: avgSessionUsage,
            hoursToday: hoursToday,
            hoursWeekAvg: hoursWeekAvg,
            hoursAllTimeAvg: hoursAllTimeAvg,
            weeklyHistory: weeklyHistory
        )
    }

    // MARK: - Persistence & Housekeeping

    private func dataWeeks() -> Double {
        guard let first = polls.first, let last = polls.last else { return 0 }
        return last.timestamp.timeIntervalSince(first.timestamp) / 604800
    }

    private func pruneOldRecords() {
        guard let latest = polls.last else { return }
        let cutoff = latest.timestamp.addingTimeInterval(-Double(Self.maxDays) * 86400)
        polls.removeAll { $0.timestamp < cutoff }
        sessionStarts.removeAll { $0.timestamp < cutoff }

        let activityCutoff = latest.timestamp.addingTimeInterval(-Double(Self.maxActivityDays) * 86400)
        dailyActivities.removeAll { $0.date < activityCutoff }
    }

    private func persist() {
        guard let url = persistURL else { return }
        DataStore.save(StoreData(polls: polls, sessions: sessionStarts, dailySnapshot: dailySnapshot, dailyActivities: dailyActivities), to: url)
    }
}
