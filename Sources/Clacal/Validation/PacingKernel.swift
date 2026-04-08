import Foundation

enum PacingKernel {
    private struct MutableWeeklyWindowSegment {
        var resetAt: Date
        var polls: [PacingPollSample]

        var duration: TimeInterval {
            guard let first = polls.first, let last = polls.last else { return 0 }
            return last.timestamp.timeIntervalSince(first.timestamp)
        }

        var maxUtilization: Double {
            polls.map(\.weeklyUsage).max() ?? 0
        }

        mutating func append(_ poll: PacingPollSample, resetAt: Date) {
            let weight = Double(polls.count)
            let blended = (self.resetAt.timeIntervalSince1970 * weight + resetAt.timeIntervalSince1970) / (weight + 1)
            self.resetAt = Date(timeIntervalSince1970: blended)
            polls.append(poll)
        }
    }

    static func resolvedWeeklyResetAt(for poll: PacingPollSample) -> Date {
        poll.weeklyResetAt ?? poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)
    }

    static func inferredWeekStart(for poll: PacingPollSample) -> Date {
        resolvedWeeklyResetAt(for: poll).addingTimeInterval(-PacingKernelConstants.weekMinutes * 60)
    }

    static func activeHoursInRange(
        from start: Date,
        to end: Date,
        schedule: PacingScheduleContext
    ) -> Double {
        guard start < end else { return 0 }

        var total = 0.0
        var cursor = start
        let calendar = schedule.calendar

        while cursor < end {
            let calendarWeekday = calendar.component(.weekday, from: cursor)
            let dayIndex = (calendarWeekday + 5) % 7
            let window = schedule.dailyWindows[dayIndex]
            let midnight = calendar.startOfDay(for: cursor)
            let windowOpen = midnight.addingTimeInterval(window.startHour * 3600)
            let windowClose = midnight.addingTimeInterval(window.endHour * 3600)
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

    static func weeklyBreakdown(
        current poll: PacingPollSample,
        history: [PacingPollSample],
        schedule: PacingScheduleContext,
        dataWeeks: Double? = nil
    ) -> WeeklyDeviationBreakdown {
        guard poll.weeklyRemaining > 0 else {
            return .init(
                source: .schedule,
                expectedUsage: 0,
                scheduleExpectedUsage: 0,
                empiricalExpectedUsage: nil,
                empiricalDiagnostics: .init(sampleCount: 0, distinctResetBucketCount: 0, bucketMismatch: false, medianUsage: nil),
                projectedFinalUsage: nil,
                activeElapsedHours: 0,
                activeRemainingHours: 0,
                activeTotalHours: 0,
                remainingFraction: 0,
                positionalTerm: 0,
                velocityDeviation: nil,
                velocityWeight: 0,
                rawDeviation: 0,
                finalDeviation: 0
            )
        }

        let elapsedMinutes = PacingKernelConstants.weekMinutes - poll.weeklyRemaining
        let weekStart = inferredWeekStart(for: poll)
        let weekEnd = poll.timestamp.addingTimeInterval(poll.weeklyRemaining * 60)
        let activeElapsed = activeHoursInRange(from: weekStart, to: poll.timestamp, schedule: schedule)
        let activeRemaining = activeHoursInRange(from: poll.timestamp, to: weekEnd, schedule: schedule)
        let activeTotal = activeElapsed + activeRemaining
        let scheduleExpected = activeTotal > 0 ? min(100, (activeElapsed / activeTotal) * 100) : 0

        let empirical = weeklyExpectedEmpirical(
            current: poll,
            history: history,
            elapsedMinutes: elapsedMinutes,
            dataWeeks: dataWeeks ?? inferredDataWeeks(from: history, including: poll)
        )
        let expected = empirical?.medianUsage ?? scheduleExpected
        let source: PacingExpectationSource = empirical == nil ? .schedule : .empirical
        let remainingFraction = max(poll.weeklyRemaining / PacingKernelConstants.weekMinutes, 0.1)
        let positional = (poll.weeklyUsage - expected) / (100 * remainingFraction)

        let projected = weeklyProjected(
            current: poll,
            activeElapsedHours: activeElapsed,
            activeRemainingHours: activeRemaining
        )
        let confidence = activeTotal > 0 ? min(activeElapsed / activeTotal, 1) : 0
        let velocityWeight = projected == nil ? 0 : 0.5 * confidence
        let velocityDeviation = projected.map { ($0 - 100) / 100 }
        let raw = if let velocityDeviation {
            (1 - velocityWeight) * positional + velocityWeight * velocityDeviation
        } else {
            positional
        }

        return .init(
            source: source,
            expectedUsage: expected,
            scheduleExpectedUsage: scheduleExpected,
            empiricalExpectedUsage: empirical?.medianUsage,
            empiricalDiagnostics: empirical?.diagnostics ?? .init(
                sampleCount: 0,
                distinctResetBucketCount: 0,
                bucketMismatch: false,
                medianUsage: nil
            ),
            projectedFinalUsage: projected,
            activeElapsedHours: activeElapsed,
            activeRemainingHours: activeRemaining,
            activeTotalHours: activeTotal,
            remainingFraction: remainingFraction,
            positionalTerm: positional,
            velocityDeviation: velocityDeviation,
            velocityWeight: velocityWeight,
            rawDeviation: raw,
            finalDeviation: tanh(2 * raw)
        )
    }

    static func sessionTarget(for weeklyDeviation: Double) -> SessionTargetBreakdown {
        .init(
            weeklyDeviation: weeklyDeviation,
            target: 100 * max(0.3, min(1, 1 - weeklyDeviation))
        )
    }

    static func sessionBudget(
        current poll: PacingPollSample,
        exchangeRate: Double?,
        remainingActiveHours: Double
    ) -> SessionBudgetBreakdown? {
        guard let exchangeRate, exchangeRate > 0 else { return nil }
        let sessionsLeft = max(remainingActiveHours / 5, 1)
        let budget = max(100 - poll.weeklyUsage, 0) / sessionsLeft
        return .init(
            exchangeRate: exchangeRate,
            remainingActiveHours: remainingActiveHours,
            sessionsLeft: sessionsLeft,
            budget: budget
        )
    }

    static func optimalRate(
        current poll: PacingPollSample,
        target: Double,
        sessionBudget: SessionBudgetBreakdown?
    ) -> OptimalRateBreakdown {
        guard poll.sessionRemaining > 0 else {
            return .init(targetRate: 0, ceilingRate: 0, budgetRate: sessionBudget.map { _ in 0 }, optimalRate: 0)
        }

        let tau = max(poll.sessionRemaining, 0.1)
        let targetRate = max((target - poll.sessionUsage) / tau, 0)
        let ceilingRate = max((100 - poll.sessionUsage) / tau, 0)
        var optimal = min(targetRate, ceilingRate)
        let budgetRate = sessionBudget.map {
            max($0.budget / max($0.exchangeRate * tau, 0.1), 0)
        }

        if let budgetRate {
            optimal = min(optimal, budgetRate)
        }

        return .init(targetRate: targetRate, ceilingRate: ceilingRate, budgetRate: budgetRate, optimalRate: optimal)
    }

    static func sessionError(
        current poll: PacingPollSample,
        target: Double
    ) -> SessionErrorBreakdown {
        guard poll.sessionRemaining > 0 else {
            return .init(expectedUsage: 0, remainingFraction: 0, error: 0)
        }

        let elapsed = PacingKernelConstants.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else {
            return .init(expectedUsage: 0, remainingFraction: max(poll.sessionRemaining / PacingKernelConstants.sessionMinutes, 0.1), error: 0)
        }

        let expectedUsage = target * (elapsed / PacingKernelConstants.sessionMinutes)
        let remainingFraction = max(poll.sessionRemaining / PacingKernelConstants.sessionMinutes, 0.1)
        let error = (poll.sessionUsage - expectedUsage) / max(100 * remainingFraction, 1)
        return .init(expectedUsage: expectedUsage, remainingFraction: remainingFraction, error: error)
    }

    static func sessionDeviation(
        current poll: PacingPollSample,
        target: Double,
        optimalRate: Double,
        currentRate: Double?
    ) -> SessionDeviationBreakdown {
        guard poll.sessionRemaining > 0 else {
            return .init(
                targetInfluence: 0,
                blendedExpectedFraction: 0,
                positionScore: 0,
                rateScore: nil,
                rateWeight: 0,
                boostedScore: 0,
                finalDeviation: 0
            )
        }

        let elapsedMinutes = PacingKernelConstants.sessionMinutes - poll.sessionRemaining
        guard elapsedMinutes >= 5 else {
            return .init(
                targetInfluence: 0,
                blendedExpectedFraction: 0,
                positionScore: 0,
                rateScore: nil,
                rateWeight: 0,
                boostedScore: 0,
                finalDeviation: 0
            )
        }

        let usageFraction = poll.sessionUsage / 100
        let elapsedFraction = elapsedMinutes / PacingKernelConstants.sessionMinutes
        let targetFraction = target / 100
        let targetInfluence = min(
            (1 - targetFraction) * PacingKernelConstants.sessionTargetInfluenceGain,
            PacingKernelConstants.sessionTargetInfluenceMax
        )
        let blendedExpectedFraction = elapsedFraction * (1 - targetInfluence)
            + (targetFraction * elapsedFraction) * targetInfluence
        let positionScore = tanh((usageFraction - blendedExpectedFraction) / PacingKernelConstants.sessionDeviationPositionScale)

        let combined: Double
        let rateScore: Double?
        let rateWeight: Double
        if let currentRate {
            let score = tanh((currentRate - optimalRate) / PacingKernelConstants.sessionDeviationRateScale)
            let weight = min(
                PacingKernelConstants.sessionDeviationRateWeightMax,
                elapsedFraction * PacingKernelConstants.sessionDeviationRateWeightMax
            )
            rateScore = score
            rateWeight = weight
            combined = (1 - weight) * positionScore + weight * score
        } else {
            rateScore = nil
            rateWeight = 0
            combined = positionScore
        }

        let boosted: Double
        if combined > 0, usageFraction > PacingKernelConstants.sessionDeviationHighUsageThreshold {
            let ramp = min(
                max(
                    (usageFraction - PacingKernelConstants.sessionDeviationHighUsageThreshold)
                        / (1 - PacingKernelConstants.sessionDeviationHighUsageThreshold),
                    0
                ),
                1
            )
            boosted = combined + (1 - combined) * PacingKernelConstants.sessionDeviationHighUsageBoostMax * ramp
        } else {
            boosted = combined
        }

        let finalDeviation = abs(boosted) < PacingKernelConstants.sessionDeviationDeadZone
            ? 0
            : max(-1, min(1, boosted))

        return .init(
            targetInfluence: targetInfluence,
            blendedExpectedFraction: blendedExpectedFraction,
            positionScore: positionScore,
            rateScore: rateScore,
            rateWeight: rateWeight,
            boostedScore: boosted,
            finalDeviation: finalDeviation
        )
    }

    // DEVLOG: Daily budget is intentionally a simple ratio of today's usage vs the
    // full-day allotment — it answers "how much of today's budget have I used?" not
    // "am I on pace through the day?" The time-proportional (active-hours) version
    // was tried and reverted.
    static func dailyBudget(
        current poll: PacingPollSample,
        snapshot: PacingDailySnapshotSample?
    ) -> DailyBudgetBreakdown {
        guard let snapshot else {
            return .init(dailyDelta: 0, daysRemaining: 0.01, dailyAllotment: 0, deviation: 0, remainingBudgetFraction: 1)
        }

        let dailyDelta = max(poll.weeklyUsage - snapshot.weeklyUsagePct, 0)
        guard dailyDelta > 0 else {
            return .init(
                dailyDelta: 0,
                daysRemaining: max(snapshot.weeklyMinsLeft / 1440.0, 0.01),
                dailyAllotment: max(100 - snapshot.weeklyUsagePct, 0) / max(snapshot.weeklyMinsLeft / 1440.0, 0.01),
                deviation: 0,
                remainingBudgetFraction: 1
            )
        }
        let daysRemaining = max(snapshot.weeklyMinsLeft / 1440.0, 0.01)
        let dailyAllotment = max(100 - snapshot.weeklyUsagePct, 0) / daysRemaining

        guard dailyAllotment > 0.01 else {
            return .init(
                dailyDelta: dailyDelta,
                daysRemaining: daysRemaining,
                dailyAllotment: dailyAllotment,
                deviation: 0,
                remainingBudgetFraction: 1
            )
        }

        let raw = dailyDelta / dailyAllotment - 1
        return .init(
            dailyDelta: dailyDelta,
            daysRemaining: daysRemaining,
            dailyAllotment: dailyAllotment,
            deviation: min(max(raw, -1), 1),
            remainingBudgetFraction: max(1 - dailyDelta / dailyAllotment, 0)
        )
    }

    static func calibrator(
        previousState: PacingCalibratorState,
        sessionError: Double,
        weeklyDeviation: Double,
        current poll: PacingPollSample
    ) -> CalibratorBreakdown {
        guard poll.sessionRemaining > 0 else {
            return .init(
                rawBlend: 0,
                deadZoned: 0,
                hysteresisOutput: 0,
                smoothedOutput: 0,
                updatedState: .init(zone: previousState.zone, previousOutput: 0)
            )
        }

        let elapsed = PacingKernelConstants.sessionMinutes - poll.sessionRemaining
        guard elapsed >= 5 else {
            return .init(
                rawBlend: 0,
                deadZoned: 0,
                hysteresisOutput: 0,
                smoothedOutput: 0,
                updatedState: previousState
            )
        }

        let sessionFraction = poll.sessionRemaining / PacingKernelConstants.sessionMinutes
        let weeklyWeight = max(1 - sessionFraction, min(abs(weeklyDeviation), 0.5))
        let raw = max(-1.0, min(1.0, (1 - weeklyWeight) * sessionError + weeklyWeight * weeklyDeviation))

        let deadZoned: Double
        if abs(raw) < 0.05 {
            deadZoned = 0
        } else {
            let sign: Double = raw > 0 ? 1 : -1
            deadZoned = sign * (abs(raw) - 0.05) / 0.95
        }

        let nextZone: PacingZoneState
        let hysteresis: Double
        switch previousState.zone {
        case .ok:
            if deadZoned > 0.12 {
                nextZone = .fast
                hysteresis = deadZoned
            } else if deadZoned < -0.12 {
                nextZone = .slow
                hysteresis = deadZoned
            } else {
                nextZone = .ok
                hysteresis = 0
            }
        case .fast:
            if deadZoned < 0.05 {
                nextZone = .ok
                hysteresis = 0
            } else {
                nextZone = .fast
                hysteresis = deadZoned
            }
        case .slow:
            if deadZoned > -0.05 {
                nextZone = .ok
                hysteresis = 0
            } else {
                nextZone = .slow
                hysteresis = deadZoned
            }
        }

        let output = max(-1, min(1, 0.25 * hysteresis + 0.75 * previousState.previousOutput))
        let updatedState = PacingCalibratorState(zone: nextZone, previousOutput: output)

        return .init(
            rawBlend: raw,
            deadZoned: deadZoned,
            hysteresisOutput: hysteresis,
            smoothedOutput: output,
            updatedState: updatedState
        )
    }

    static func didWeeklyReset(previous: PacingPollSample, current: PacingPollSample) -> Bool {
        guard current.weeklyRemaining - previous.weeklyRemaining > 60 else { return false }

        let previousResetAt = resolvedWeeklyResetAt(for: previous)
        let currentResetAt = resolvedWeeklyResetAt(for: current)
        let resetMovedForward = currentResetAt.timeIntervalSince(previousResetAt) > PacingKernelConstants.weeklyResetTolerance
        let usageRestarted = current.weeklyUsage <= previous.weeklyUsage

        return resetMovedForward && usageRestarted
    }

    static func weeklyHistory(
        polls: [PacingPollSample],
        now: Date
    ) -> [PacingHistoryEntry] {
        weeklyWindowSegments(polls: polls)
            .filter { $0.resetAt <= now }
            .filter { !$0.isTransient }
            .compactMap { segment in
                guard segment.maxUtilization > 0 else { return nil }
                return PacingHistoryEntry(windowEnd: segment.resetAt, utilization: segment.maxUtilization)
            }
            .sorted { $0.windowEnd > $1.windowEnd }
    }

    static func weeklyWindowSegments(polls: [PacingPollSample]) -> [PacingWeeklyWindowSegment] {
        var segments: [MutableWeeklyWindowSegment] = []

        for poll in polls {
            let resetAt = resolvedWeeklyResetAt(for: poll)
            if let index = segments.firstIndex(where: {
                abs($0.resetAt.timeIntervalSince(resetAt)) <= PacingKernelConstants.weeklyResetTolerance
            }) {
                segments[index].append(poll, resetAt: resetAt)
            } else {
                segments.append(.init(resetAt: resetAt, polls: [poll]))
            }
        }

        return segments
            .map { segment in
                let ordered = segment.polls.sorted { $0.timestamp < $1.timestamp }
                let duration: TimeInterval = if let first = ordered.first, let last = ordered.last {
                    last.timestamp.timeIntervalSince(first.timestamp)
                } else {
                    0
                }
                return PacingWeeklyWindowSegment(
                    resetAt: segment.resetAt,
                    pollCount: ordered.count,
                    duration: duration,
                    maxUtilization: ordered.map(\.weeklyUsage).max() ?? 0
                )
            }
            .sorted { $0.resetAt < $1.resetAt }
    }

    private static func inferredDataWeeks(from history: [PacingPollSample], including current: PacingPollSample) -> Double {
        let timestamps = (history + [current]).map(\.timestamp).sorted()
        guard let first = timestamps.first, let last = timestamps.last else { return 0 }
        return last.timeIntervalSince(first) / 604800
    }

    private static func weeklyProjected(
        current poll: PacingPollSample,
        activeElapsedHours: Double,
        activeRemainingHours: Double
    ) -> Double? {
        guard activeElapsedHours >= PacingKernelConstants.minActiveHoursForProjection else { return nil }
        return poll.weeklyUsage + (poll.weeklyUsage / activeElapsedHours) * activeRemainingHours
    }

    private static func weeklyExpectedEmpirical(
        current poll: PacingPollSample,
        history: [PacingPollSample],
        elapsedMinutes: Double,
        dataWeeks: Double
    ) -> (medianUsage: Double, diagnostics: EmpiricalExpectationDiagnostics)? {
        guard dataWeeks >= PacingKernelConstants.empiricalWeeksRequired else { return nil }

        let cutoff = poll.timestamp.addingTimeInterval(-7 * 86400)
        let samples = history
            .filter { $0.timestamp < cutoff }
            .filter { abs((PacingKernelConstants.weekMinutes - $0.weeklyRemaining) - elapsedMinutes) < 15 }

        guard samples.count >= PacingKernelConstants.empiricalMinSamples else { return nil }

        let usages = samples.map(\.weeklyUsage).sorted()
        let weekSeconds = PacingKernelConstants.weekMinutes * 60
        let buckets = Set(samples.map {
            Int(normalizedResetSlot(for: resolvedWeeklyResetAt(for: $0), weekSeconds: weekSeconds)
                / PacingKernelConstants.empiricalResetBucketWidth)
        })
        let median = usages[usages.count / 2]

        return (
            medianUsage: median,
            diagnostics: .init(
                sampleCount: samples.count,
                distinctResetBucketCount: buckets.count,
                bucketMismatch: buckets.count > 1,
                medianUsage: median
            )
        )
    }

    private static func normalizedResetSlot(for resetAt: Date, weekSeconds: Double) -> Double {
        let raw = resetAt.timeIntervalSince1970.truncatingRemainder(dividingBy: weekSeconds)
        return raw >= 0 ? raw : raw + weekSeconds
    }
}

private extension PacingWeeklyWindowSegment {
    var isTransient: Bool {
        pollCount <= PacingKernelConstants.weeklyTransientMaxPolls
            && duration <= PacingKernelConstants.weeklyTransientMaxDuration
    }
}
