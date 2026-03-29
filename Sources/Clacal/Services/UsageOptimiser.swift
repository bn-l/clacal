import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "Optimiser")

private enum PacingZone {
    case ok, fast, slow
}

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
    static let sessionMinutes: Double = 300
    static let weekMinutes: Double = 10080

    private static let maxDays = 90
    private static let emaAlpha = 0.3
    private static let gapThresholdMinutes: Double = 15
    private static let boundaryJumpMinutes: Double = 30
    private static let minExchangeRateSamples = 10
    private static let empiricalWeeksRequired: Double = 3
    private static let empiricalMatchToleranceMinutes: Double = 180
    private static let empiricalFullConfidenceWeeks: Double = 6
    private static let weeklyScheduleBiasCap: Double = 6
    private static let weeklyScheduleBiasWeight: Double = 0.25
    private static let weeklyEmpiricalBiasCapStart: Double = 12
    private static let weeklyEmpiricalBiasCapEnd: Double = 4
    private static let weeklyGapScaleStart: Double = 18
    private static let weeklyGapScaleEnd: Double = 10
    private static let weeklyProjectionWeightStart: Double = 0.1
    private static let weeklyProjectionWeightEnd: Double = 0.3
    private static let windowDetectionMinPolls = 3
    private static let windowDetectionDaysRequired: Double = 7

    private static let dayResetHour = 5 // 5am local time
    private static let idleGraceMinutes: Double = 30
    private static let maxActivityDays = 365

    private(set) var polls: [Poll]
    private(set) var sessionStarts: [SessionStart]
    private(set) var dailySnapshot: DailySnapshot?
    private(set) var dailyActivities: [DailyActivity]
    private var detectedWindows: [(start: Double, end: Double)]
    private let persistURL: URL?
    private var pacingZone: PacingZone = .ok
    private var prevCalOutput: Double = 0

    // Idle tracking state
    private var lastUsageGrowth: Date?
    private var pendingGraceMinutes: Double = 0

    init(
        data: StoreData = StoreData(),
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        persistURL: URL? = nil
    ) {
        self.polls = data.polls
        self.sessionStarts = data.sessions
        self.dailySnapshot = data.dailySnapshot
        self.dailyActivities = data.dailyActivities
        self.persistURL = persistURL
        // Normalise to exactly 7 entries (pad with 10h default, truncate excess)
        let padded = (activeHoursPerDay + Array(repeating: 10.0, count: 7)).prefix(7)
        self.detectedWindows = padded.map { hours in
            (start: 10.0, end: min(10.0 + hours, 24.0))
        }

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
        timestamp: Date = Date()
    ) -> OptimiserResult {
        let poll = Poll(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining
        )

        let isNewSession = detectSessionBoundary(poll)
        if isNewSession {
            sessionStarts.append(SessionStart(
                timestamp: timestamp,
                weeklyUsage: weeklyUsage,
                weeklyRemaining: weeklyRemaining
            ))
            pacingZone = .ok
            prevCalOutput = 0
            logger.info("New session detected at \(timestamp, privacy: .public) weeklyUsage=\(weeklyUsage, privacy: .public)")
        }

        polls.append(poll)
        trackActivity(poll, isNewSession: isNewSession)
        pruneOldRecords()
        maybeUpdateDetectedWindows()
        maybeUpdateDailySnapshot(poll)

        let deviation = weeklyDeviation(poll)
        let target = sessionTarget(deviation)
        let budget = sessionBudget(poll)
        let optimal = optimalRate(poll, target: target, budget: budget)
        let velocity = sessionVelocity()
        let sError = sessionError(poll, target: target)
        let cal = calibrator(sessionError: sError, deviation: deviation, poll: poll)
        let sDev = sessionDeviation(poll, target: target)
        let dDev = dailyDeviation(poll)
        let dRemaining = dailyBudgetRemaining(poll)

        persist()

        logger.info("Poll recorded: calibrator=\(cal, privacy: .public) target=\(target, privacy: .public) optimalRate=\(optimal, privacy: .public) weeklyDev=\(deviation, privacy: .public) sessionDev=\(sDev, privacy: .public) dailyDev=\(dDev, privacy: .public) dailyRemaining=\(dRemaining, privacy: .public) newSession=\(isNewSession, privacy: .public)")

        return OptimiserResult(
            calibrator: cal,
            target: target,
            optimalRate: optimal,
            currentRate: velocity,
            weeklyDeviation: deviation,
            exchangeRate: exchangeRate(),
            sessionBudget: budget,
            isNewSession: isNewSession,
            sessionDeviation: sDev,
            dailyDeviation: dDev,
            dailyBudgetRemaining: dRemaining
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

    // MARK: - Stage 1: Weekly Deviation

    private func weeklyDeviation(_ poll: Poll) -> Double {
        guard poll.weeklyRemaining > 0 else { return 0 }

        let elapsedPct = weeklyElapsedPercent(poll)
        let expected = weeklyExpected(poll)
        let elapsedFrac = elapsedPct / 100
        let scale = interpolate(
            from: Self.weeklyGapScaleStart,
            to: Self.weeklyGapScaleEnd,
            fraction: elapsedFrac
        )

        var raw = (poll.weeklyUsage - expected) / scale
        if let projected = weeklyProjected(poll) {
            let finishGap = clamp((projected - 100) / 20, lower: -1, upper: 1)
            let projectionWeight = interpolate(
                from: Self.weeklyProjectionWeightStart,
                to: Self.weeklyProjectionWeightEnd,
                fraction: elapsedFrac
            )
            raw = (1 - projectionWeight) * raw + projectionWeight * finishGap
        }
        if abs(raw) < 0.05 {
            return 0
        }
        return tanh(raw)
    }

    private func weeklyExpected(_ poll: Poll) -> Double {
        let elapsedMinutes = Self.weekMinutes - poll.weeklyRemaining
        let elapsedPct = weeklyElapsedPercent(poll)
        let scheduleBias = weeklyScheduleBias(poll, elapsedPct: elapsedPct)
        let empiricalBias = weeklyEmpiricalBias(poll, elapsedMinutes: elapsedMinutes, elapsedPct: elapsedPct)
        return clamp(elapsedPct + scheduleBias + empiricalBias, lower: 0, upper: 100)
    }

    private func weeklyExpectedFromSchedule(_ poll: Poll) -> Double {
        let elapsedMinutes = Self.weekMinutes - poll.weeklyRemaining
        let weekStart = poll.timestamp.addingTimeInterval(-elapsedMinutes * 60)
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)

        let activeElapsed = activeHoursInRange(from: weekStart, to: poll.timestamp)
        let activeTotal = activeHoursInRange(from: weekStart, to: weekEnd)

        guard activeTotal > 0 else { return 0 }
        return min(100, (activeElapsed / activeTotal) * 100)
    }

    private func weeklyProjected(_ poll: Poll) -> Double? {
        guard let velocity = weeklyVelocity() else { return nil }
        let remainingActiveMinutes = max(remainingActiveHours(poll) * 60, 0)
        return poll.weeklyUsage + velocity * remainingActiveMinutes
    }

    private func weeklyExpectedEmpirical(_ poll: Poll, elapsedMinutes: Double) -> (medianUsage: Double, sampleCount: Int)? {
        guard dataWeeks() >= Self.empiricalWeeksRequired else { return nil }

        let cutoff = poll.timestamp.addingTimeInterval(-7 * 86400)
        let values = historicalWeeks(endingBefore: cutoff)
            .compactMap { nearestWeeklyUsage(in: $0, elapsedMinutes: elapsedMinutes) }
            .sorted()

        guard values.count >= Int(Self.empiricalWeeksRequired.rounded(.up)) else { return nil }
        return (median(values), values.count)
    }

    // MARK: - Stage 2: Session Target & Budget

    private func sessionTarget(_ deviation: Double) -> Double {
        100 * max(0.3, min(1, 1 - deviation))
    }

    private func sessionBudget(_ poll: Poll) -> Double? {
        guard let rate = exchangeRate(), rate > 0 else { return nil }
        let remainingHours = remainingActiveHours(poll)
        let sessionsLeft = max(remainingHours / 5, 1)
        return max(100 - poll.weeklyUsage, 0) / sessionsLeft
    }

    private func remainingActiveHours(_ poll: Poll) -> Double {
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)
        return activeHoursInRange(from: poll.timestamp, to: weekEnd)
    }

    // MARK: - Stage 3: Optimal Rate

    private func optimalRate(_ poll: Poll, target: Double, budget: Double?) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }

        let tau = max(poll.sessionRemaining, 0.1)
        let targetRate = max((target - poll.sessionUsage) / tau, 0)
        let ceilingRate = max((100 - poll.sessionUsage) / tau, 0)

        var rate = min(targetRate, ceilingRate)

        if let xr = exchangeRate(), xr > 0, let budget {
            let budgetRate = max(budget / (xr * tau), 0)
            rate = min(rate, budgetRate)
        }

        return rate
    }

    // MARK: - Session Error (shared by calibrator + dual bar)

    private func sessionError(_ poll: Poll, target: Double) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }
        let elapsed = Self.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else { return 0 }
        let expectedUsage = target * (elapsed / Self.sessionMinutes)
        let remainingFrac = max(poll.sessionRemaining / Self.sessionMinutes, 0.1)
        return (poll.sessionUsage - expectedUsage) / max(100 * remainingFrac, 1)
    }

    private func sessionDeviation(_ poll: Poll, target: Double) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }

        let elapsedMinutes = Self.sessionMinutes - poll.sessionRemaining
        guard elapsedMinutes >= 5 else { return 0 }

        let usageFrac = poll.sessionUsage / 100
        let elapsedFrac = elapsedMinutes / Self.sessionMinutes
        let delta = usageFrac - (target / 100) * elapsedFrac

        // Behind pace: constant 2× keeps the reading stable across the whole
        // session (no normalizer that blows up at either extreme).
        // Ahead of pace: scale against remaining headroom so the over-pacing
        // signal ramps up as the session budget runs out.
        let raw: Double
        if delta >= 0 {
            let normalizer = max(poll.sessionRemaining / Self.sessionMinutes, 0.1)
            raw = tanh(delta / normalizer)
        } else {
            raw = tanh(2 * delta)
        }

        return raw > 0 ? min(raw * exp(pow(usageFrac, 8)), 1) : raw
    }

    // MARK: - Stage 4: Calibrator (PB+Pipe)

    private func calibrator(sessionError: Double, deviation: Double, poll: Poll) -> Double {
        guard poll.sessionRemaining > 0 else { return 0 }

        let elapsed = Self.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else { return 0 }

        // Blend: session error + weekly deviation, with minimum weekly weight
        // when deviation is extreme so a -100% weekly deficit isn't swallowed
        let sFrac = poll.sessionRemaining / Self.sessionMinutes
        let wWeight = max(1 - sFrac, min(abs(deviation), 0.5))
        let raw = max(-1.0, min(1.0, (1 - wWeight) * sessionError + wWeight * deviation))

        // Dead zone — suppress small signals
        let dz: Double
        if abs(raw) < 0.05 {
            dz = 0
        } else {
            let sign: Double = raw > 0 ? 1 : -1
            dz = sign * (abs(raw) - 0.05) / 0.95
        }

        // Hysteresis — prevent oscillation at zone boundaries
        let hz: Double
        switch pacingZone {
        case .ok:
            if dz > 0.12 {
                pacingZone = .fast
                hz = dz
            } else if dz < -0.12 {
                pacingZone = .slow
                hz = dz
            } else {
                hz = 0
            }
        case .fast:
            if dz < 0.05 {
                pacingZone = .ok
                hz = 0
            } else {
                hz = dz
            }
        case .slow:
            if dz > -0.05 {
                pacingZone = .ok
                hz = 0
            } else {
                hz = dz
            }
        }

        // Smoothing — slew-rate limit for stable display
        let output = 0.25 * hz + 0.75 * prevCalOutput
        prevCalOutput = output
        return max(-1, min(1, output))
    }

    // MARK: - Velocity Estimation

    private func sessionVelocity() -> Double? {
        guard let sessionStart = currentSessionStartTimestamp else { return nil }
        let sessionPolls = polls.filter { $0.timestamp >= sessionStart }
        return emaVelocity(sessionPolls) { $0.sessionUsage }
    }

    private func weeklyVelocity() -> Double? {
        guard polls.count >= 2 else { return nil }
        var ema: Double?
        for index in 1..<polls.count {
            let previous = polls[index - 1]
            let current = polls[index]
            let deltaMinutes = current.timestamp.timeIntervalSince(previous.timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { continue }
            guard current.weeklyRemaining <= previous.weeklyRemaining else { continue }

            let deltaWeekly = current.weeklyUsage - previous.weeklyUsage
            guard deltaWeekly >= 0 else { continue }

            let instantVelocity = deltaWeekly / deltaMinutes
            ema = ema.map { Self.emaAlpha * instantVelocity + (1 - Self.emaAlpha) * $0 } ?? instantVelocity
        }
        return ema
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
        for index in 1..<polls.count {
            guard !spansSessionBoundary(from: polls[index - 1].timestamp, to: polls[index].timestamp) else {
                continue
            }
            let deltaMinutes = polls[index].timestamp.timeIntervalSince(polls[index - 1].timestamp) / 60
            guard deltaMinutes > 0, deltaMinutes <= Self.gapThresholdMinutes else { continue }
            let deltaSession = polls[index].sessionUsage - polls[index - 1].sessionUsage
            let deltaWeekly = polls[index].weeklyUsage - polls[index - 1].weeklyUsage
            if deltaSession > 0.5 {
                ratios.append(deltaWeekly / deltaSession)
            }
        }
        guard ratios.count >= Self.minExchangeRateSamples else { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    private func spansSessionBoundary(from start: Date, to end: Date) -> Bool {
        sessionStarts.contains { $0.timestamp > start && $0.timestamp <= end }
    }

    private func weeklyElapsedPercent(_ poll: Poll) -> Double {
        clamp((Self.weekMinutes - poll.weeklyRemaining) / Self.weekMinutes * 100, lower: 0, upper: 100)
    }

    private func weeklyScheduleBias(_ poll: Poll, elapsedPct: Double) -> Double {
        let rawBias = weeklyExpectedFromSchedule(poll) - elapsedPct
        let capped = clamp(rawBias, lower: -Self.weeklyScheduleBiasCap, upper: Self.weeklyScheduleBiasCap)
        return capped * Self.weeklyScheduleBiasWeight
    }

    private func weeklyEmpiricalBias(_ poll: Poll, elapsedMinutes: Double, elapsedPct: Double) -> Double {
        guard let empirical = weeklyExpectedEmpirical(poll, elapsedMinutes: elapsedMinutes) else { return 0 }

        let elapsedFrac = elapsedPct / 100
        let cap = interpolate(
            from: Self.weeklyEmpiricalBiasCapStart,
            to: Self.weeklyEmpiricalBiasCapEnd,
            fraction: elapsedFrac
        )
        let confidence = min(Double(empirical.sampleCount) / Self.empiricalFullConfidenceWeeks, 1)
        let rawBias = empirical.medianUsage - elapsedPct
        return confidence * clamp(rawBias, lower: -cap, upper: cap)
    }

    private func historicalWeeks(endingBefore cutoff: Date) -> [[Poll]] {
        guard let first = polls.first else { return [] }

        var weeks: [[Poll]] = []
        var currentWeek = [first]

        for poll in polls.dropFirst() {
            if poll.weeklyRemaining - currentWeek.last!.weeklyRemaining > 60 {
                if let last = currentWeek.last, last.timestamp < cutoff {
                    weeks.append(currentWeek)
                }
                currentWeek = [poll]
            } else {
                currentWeek.append(poll)
            }
        }

        if let last = currentWeek.last, last.timestamp < cutoff {
            weeks.append(currentWeek)
        }

        return weeks
    }

    private func nearestWeeklyUsage(in week: [Poll], elapsedMinutes: Double) -> Double? {
        guard week.count >= 3 else { return nil }
        guard let nearest = week.min(by: {
            abs((Self.weekMinutes - $0.weeklyRemaining) - elapsedMinutes)
                < abs((Self.weekMinutes - $1.weeklyRemaining) - elapsedMinutes)
        }) else {
            return nil
        }

        let distance = abs((Self.weekMinutes - nearest.weeklyRemaining) - elapsedMinutes)
        guard distance <= Self.empiricalMatchToleranceMinutes else { return nil }
        return nearest.weeklyUsage
    }

    private func interpolate(from start: Double, to end: Double, fraction: Double) -> Double {
        let clamped = clamp(fraction, lower: 0, upper: 1)
        return start + (end - start) * clamped
    }

    private func clamp(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }

    private func median(_ values: [Double]) -> Double {
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    // MARK: - Active Hours Schedule

    func activeHoursInRange(from start: Date, to end: Date) -> Double {
        var total: Double = 0
        let calendar = Calendar.current
        var cursor = start

        while cursor < end {
            // Calendar weekday: 1=Sun, 2=Mon, ..., 7=Sat
            // We need: 0=Mon, 1=Tue, ..., 6=Sun
            let calendarWeekday = calendar.component(.weekday, from: cursor)
            let dayIndex = (calendarWeekday + 5) % 7

            let window = detectedWindows[dayIndex]
            let midnight = calendar.startOfDay(for: cursor)
            let windowOpen = midnight.addingTimeInterval(window.start * 3600)
            let windowClose = midnight.addingTimeInterval(window.end * 3600)
            let nextDay = calendar.date(byAdding: .day, value: 1, to: midnight)!

            let segmentEnd = min(end, nextDay)
            let overlapStart = max(cursor, windowOpen)
            let overlapEnd = min(segmentEnd, windowClose)

            if overlapEnd > overlapStart {
                total += overlapEnd.timeIntervalSince(overlapStart) / 3600
            }

            cursor = nextDay
        }
        return total
    }

    // MARK: - Window Auto-Detection

    private func maybeUpdateDetectedWindows() {
        guard let firstPoll = polls.first else { return }
        let daysSinceFirst = Date().timeIntervalSince(firstPoll.timestamp) / 86400
        guard daysSinceFirst >= Self.windowDetectionDaysRequired else { return }

        let calendar = Calendar.current

        for dayIndex in 0..<7 {
            var activeHours: [Double] = []

            for index in 1..<polls.count {
                guard !spansSessionBoundary(from: polls[index - 1].timestamp, to: polls[index].timestamp) else {
                    continue
                }
                let deltaSession = polls[index].sessionUsage - polls[index - 1].sessionUsage
                guard deltaSession > 0.5 else { continue }

                let calendarWeekday = calendar.component(.weekday, from: polls[index].timestamp)
                let pollDayIndex = (calendarWeekday + 5) % 7
                guard pollDayIndex == dayIndex else { continue }

                let hour = Double(calendar.component(.hour, from: polls[index].timestamp))
                    + Double(calendar.component(.minute, from: polls[index].timestamp)) / 60
                activeHours.append(hour)
            }

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
        let calendar = Calendar.current
        let boundary = dayBoundary(for: poll.timestamp, calendar: calendar)

        if let existing = dailySnapshot {
            let existingBoundary = dayBoundary(for: existing.date, calendar: calendar)
            let weeklyReset = polls.count >= 2
                && poll.weeklyRemaining - polls[polls.count - 2].weeklyRemaining > 60
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

    // DEVLOG: Do NOT uncomment the time-proportional (active-hours) version below.
    // Daily budget is intentionally a simple ratio of today's usage vs the full-day
    // allotment — it answers "how much of today's budget have I used?" not "am I
    // on pace through the day?" The latter was tried and reverted.
    private func dailyDeviation(_ poll: Poll) -> Double {
        guard let snapshot = dailySnapshot else { return 0 }
        let dailyDelta = max(poll.weeklyUsage - snapshot.weeklyUsagePct, 0)
        guard dailyDelta > 0 else { return 0 }
        let daysRemaining = max(snapshot.weeklyMinsLeft / 1440.0, 0.01)
        let dailyAllotment = max(100 - snapshot.weeklyUsagePct, 0) / daysRemaining
        guard dailyAllotment > 0.01 else { return 0 }

        let raw = dailyDelta / dailyAllotment - 1
        return min(max(raw, -1), 1)
    }

    private func dailyBudgetRemaining(_ poll: Poll) -> Double {
        guard let snapshot = dailySnapshot else { return 1 }
        let dailyDelta = max(poll.weeklyUsage - snapshot.weeklyUsagePct, 0)
        let daysRemaining = max(snapshot.weeklyMinsLeft / 1440.0, 0.01)
        let dailyAllotment = max(100 - snapshot.weeklyUsagePct, 0) / daysRemaining
        guard dailyAllotment > 0.01 else { return 1 }
        return max(1 - dailyDelta / dailyAllotment, 0)
    }

    // MARK: - Idle Tracking

    private func trackActivity(_ poll: Poll, isNewSession: Bool) {
        let calendar = Calendar.current

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
        let calendar = Calendar.current
        let now = Date()
        let todayBound = dayBoundary(for: now, calendar: calendar)

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
        if let latest = polls.last {
            let weekElapsed = Self.weekMinutes - latest.weeklyRemaining
            let weekStart = latest.timestamp.addingTimeInterval(-weekElapsed * 60)
            let daysThisWeek = max(now.timeIntervalSince(weekStart) / 86400, 1)
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

        // Weekly utilization history — detect resets (weeklyRemaining jumps >60min)
        var weeklyHistory: [UsageStats.WeeklyEntry] = []
        for i in 1..<polls.count {
            let jump = polls[i].weeklyRemaining - polls[i - 1].weeklyRemaining
            if jump > 60, polls[i - 1].weeklyRemaining > 0 {
                let util = polls[i - 1].weeklyUsage
                let elapsed = Self.weekMinutes - polls[i - 1].weeklyRemaining
                let weekStart = polls[i - 1].timestamp.addingTimeInterval(-elapsed * 60)
                weeklyHistory.append(.init(weekStart: weekStart, utilization: util))
            }
        }

        // Append current week
        if let latest = polls.last {
            let elapsed = Self.weekMinutes - latest.weeklyRemaining
            let weekStart = latest.timestamp.addingTimeInterval(-elapsed * 60)
            let isDuplicate = weeklyHistory.last.map {
                abs(weekStart.timeIntervalSince($0.weekStart)) < 86400
            } ?? false
            if !isDuplicate {
                weeklyHistory.append(.init(weekStart: weekStart, utilization: latest.weeklyUsage))
            }
        }

        weeklyHistory.reverse()
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
