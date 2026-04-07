import Foundation

enum PacingFixtureLibrary {
    static func allFixtures() -> [PacingValidationFixture] {
        [
            onPaceNearWeekEnd(),
            resetBridgeKeepsCompleted97Week(),
            placeholderArtifactDoesNotCreateWeek(),
            midWeekZeroRecoveryDoesNotCreateWeek(),
            resetDeadlineShiftedWindowsStayStable(),
            dstCrossingHistoryAndSchedule(),
            noEmpiricalBeforeThreeWeeks(),
            empiricalPoisoningNearWeekEndDetection(),
            allDayScheduleDriftStillTracksHistory(),
            restartSparsePollingRestoresState(),
        ]
    }

    static func fixture(named name: String) -> PacingValidationFixture? {
        allFixtures().first { $0.name == name }
    }

    private static func onPaceNearWeekEnd() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = allDaySchedule(timeZone: tz)
        let resetAt = date(2026, 4, 13, 8, 0, timeZone: tz)
        let steps = [
            step(at: date(2026, 4, 7, 8, 0, timeZone: tz), sessionUsage: 5, sessionRemaining: 295, weeklyUsage: 4, resetAt: resetAt, label: "week-start"),
            step(at: date(2026, 4, 10, 20, 0, timeZone: tz), sessionUsage: 44, sessionRemaining: 180, weeklyUsage: 57, resetAt: resetAt, label: "steady"),
            step(at: date(2026, 4, 12, 10, 8, timeZone: tz), sessionUsage: 10, sessionRemaining: 112, weeklyUsage: 86, resetAt: resetAt, label: "near-parity"),
        ]

        return .init(
            name: "on_pace_near_week_end",
            description: "On-pace weekly usage near the end of a week with no empirical branch available.",
            tags: ["fast", "weekly", "on-pace"],
            schedule: schedule,
            initialData: StoreData(),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [],
            onPaceTolerance: 2.5,
            onPaceDeviationLimit: 0.25
        )
    }

    private static func resetBridgeKeepsCompleted97Week() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = workdaySchedule(timeZone: tz, startHour: 10, endHour: 20)

        let mar15 = date(2026, 3, 15, 17, 0, timeZone: tz)
        let mar22 = date(2026, 3, 22, 20, 0, timeZone: tz)
        let mar29 = date(2026, 3, 29, 20, 0, timeZone: tz)
        let apr5 = date(2026, 4, 5, 19, 0, timeZone: tz)

        var polls: [Poll] = []
        polls += completedWeekSegment(windowEnd: mar15, utilization: 34, timeZone: tz)
        polls += completedWeekSegment(windowEnd: mar22, utilization: 35, timeZone: tz)
        polls += [
            poll(at: date(2026, 3, 29, 17, 0, timeZone: tz), sessionUsage: 40, sessionRemaining: 180, weeklyUsage: 95, weeklyRemaining: minutesUntil(mar29, from: date(2026, 3, 29, 17, 0, timeZone: tz)), weeklyResetAt: mar29),
            poll(at: date(2026, 3, 29, 18, 30, timeZone: tz), sessionUsage: 55, sessionRemaining: 90, weeklyUsage: 96, weeklyRemaining: minutesUntil(mar29, from: date(2026, 3, 29, 18, 30, timeZone: tz)), weeklyResetAt: mar29),
        ]
        let initialData = storeData(polls: polls, sessionStartIndices: [0, 3, 6])

        let steps = [
            step(at: date(2026, 3, 29, 19, 59, timeZone: tz), sessionUsage: 70, sessionRemaining: 1, weeklyUsage: 97, resetAt: mar29, label: "last-good"),
            PacingReplayStep(
                timestamp: date(2026, 3, 29, 20, 9, timeZone: tz),
                sessionUsage: 0,
                sessionRemaining: 0,
                weeklyUsage: 0,
                weeklyRemaining: 0,
                weeklyResetAt: mar29,
                label: "zero-plateau"
            ),
            step(at: date(2026, 3, 29, 20, 17, timeZone: tz), sessionUsage: 0, sessionRemaining: 300, weeklyUsage: 0, resetAt: apr5, label: "new-window"),
            step(at: date(2026, 3, 30, 12, 0, timeZone: tz), sessionUsage: 12, sessionRemaining: 228, weeklyUsage: 5, resetAt: apr5, label: "current-week"),
        ]

        return .init(
            name: "reset_bridge_keeps_completed_97pct_week",
            description: "A real reset bridge with a transient 0/0 plateau must still retain the completed 97% week.",
            tags: ["fast", "weekly-history", "reset-bridge"],
            schedule: schedule,
            initialData: initialData,
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [
                .init(windowEnd: mar29, utilization: 97),
                .init(windowEnd: mar22, utilization: 35),
                .init(windowEnd: mar15, utilization: 34),
            ],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func placeholderArtifactDoesNotCreateWeek() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = workdaySchedule(timeZone: tz, startHour: 10, endHour: 20)

        let feb20 = date(2026, 2, 20, 14, 0, timeZone: tz)
        let feb27 = date(2026, 2, 27, 15, 0, timeZone: tz)
        let mar6 = date(2026, 3, 6, 14, 0, timeZone: tz)
        let mar15 = date(2026, 3, 15, 17, 0, timeZone: tz)

        var polls: [Poll] = []
        polls += completedWeekSegment(windowEnd: feb20, utilization: 84, timeZone: tz)
        polls += completedWeekSegment(windowEnd: feb27, utilization: 64, timeZone: tz)
        polls += completedWeekSegment(windowEnd: mar6, utilization: 63, timeZone: tz)
        polls += [
            poll(at: date(2026, 3, 12, 9, 15, timeZone: tz), sessionUsage: 12, sessionRemaining: 180, weeklyUsage: 7, weeklyRemaining: 4241.848),
            poll(at: date(2026, 3, 12, 9, 45, timeZone: tz), sessionUsage: 10, sessionRemaining: 280, weeklyUsage: 20, weeklyRemaining: 8000),
            poll(at: date(2026, 3, 12, 10, 5, timeZone: tz), sessionUsage: 13, sessionRemaining: 260, weeklyUsage: 9, weeklyRemaining: minutesUntil(mar15, from: date(2026, 3, 12, 10, 5, timeZone: tz)), weeklyResetAt: mar15),
        ]
        polls += completedWeekSegment(windowEnd: mar15, utilization: 34, timeZone: tz)

        return .init(
            name: "placeholder_artifact_does_not_create_week",
            description: "Rounded 20%/8000 placeholder polls must not generate synthetic weekly history entries.",
            tags: ["fast", "weekly-history", "artifact"],
            schedule: schedule,
            initialData: storeData(polls: polls, sessionStartIndices: [0, 3, 6, 9]),
            steps: [],
            evaluationDate: mar15.addingTimeInterval(3600),
            expectedOutcome: .pass,
            expectedWeeklyHistory: [
                .init(windowEnd: mar15, utilization: 34),
                .init(windowEnd: mar6, utilization: 63),
                .init(windowEnd: feb27, utilization: 64),
                .init(windowEnd: feb20, utilization: 84),
            ],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func midWeekZeroRecoveryDoesNotCreateWeek() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = workdaySchedule(timeZone: tz, startHour: 10, endHour: 20)

        let feb20 = date(2026, 2, 20, 14, 0, timeZone: tz)
        let feb27 = date(2026, 2, 27, 15, 0, timeZone: tz)
        let mar6 = date(2026, 3, 6, 14, 0, timeZone: tz)

        var polls: [Poll] = []
        polls += completedWeekSegment(windowEnd: feb20, utilization: 84, timeZone: tz)
        polls += completedWeekSegment(windowEnd: feb27, utilization: 64, timeZone: tz)
        polls += [
            poll(at: date(2026, 3, 4, 11, 38, timeZone: tz), sessionUsage: 32, sessionRemaining: 205, weeklyUsage: 59, weeklyRemaining: minutesUntil(mar6, from: date(2026, 3, 4, 11, 38, timeZone: tz)), weeklyResetAt: mar6),
            poll(at: date(2026, 3, 4, 11, 44, timeZone: tz), sessionUsage: 0, sessionRemaining: 0, weeklyUsage: 0, weeklyRemaining: 0),
            poll(at: date(2026, 3, 4, 11, 49, timeZone: tz), sessionUsage: 0, sessionRemaining: 0, weeklyUsage: 0, weeklyRemaining: 0),
            poll(at: date(2026, 3, 4, 12, 5, timeZone: tz), sessionUsage: 35, sessionRemaining: 185, weeklyUsage: 61, weeklyRemaining: minutesUntil(mar6, from: date(2026, 3, 4, 12, 5, timeZone: tz)), weeklyResetAt: mar6),
        ]
        polls += completedWeekSegment(windowEnd: mar6, utilization: 63, timeZone: tz)

        return .init(
            name: "midweek_zero_recovery_does_not_create_week",
            description: "A transient mid-week 0/0 outage must not create or drop completed weeks.",
            tags: ["fast", "weekly-history", "zero-recovery"],
            schedule: schedule,
            initialData: storeData(polls: polls, sessionStartIndices: [0, 3, 9]),
            steps: [],
            evaluationDate: mar6.addingTimeInterval(3600),
            expectedOutcome: .pass,
            expectedWeeklyHistory: [
                .init(windowEnd: mar6, utilization: 63),
                .init(windowEnd: feb27, utilization: 64),
                .init(windowEnd: feb20, utilization: 84),
            ],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func resetDeadlineShiftedWindowsStayStable() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = workdaySchedule(timeZone: tz, startHour: 10, endHour: 20)

        let windows: [(Date, Double)] = [
            (date(2026, 2, 20, 14, 0, timeZone: tz), 84),
            (date(2026, 2, 27, 15, 0, timeZone: tz), 64),
            (date(2026, 3, 6, 14, 0, timeZone: tz), 63),
            (date(2026, 3, 15, 17, 0, timeZone: tz), 34),
            (date(2026, 3, 22, 20, 0, timeZone: tz), 35),
        ]
        let polls = windows.enumerated().flatMap { _, window in
            completedWeekSegment(windowEnd: window.0, utilization: window.1, timeZone: tz)
        }

        return .init(
            name: "shifted_reset_deadlines_stay_stable",
            description: "Weekly history should respect shifted reset deadlines instead of assuming a fixed wall-clock week.",
            tags: ["fast", "weekly-history", "reset-drift"],
            schedule: schedule,
            initialData: storeData(polls: polls, sessionStartIndices: [0, 3, 6, 9, 12]),
            steps: [],
            evaluationDate: windows.last!.0.addingTimeInterval(3600),
            expectedOutcome: .pass,
            expectedWeeklyHistory: windows.reversed().map { .init(windowEnd: $0.0, utilization: $0.1) },
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func dstCrossingHistoryAndSchedule() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = workdaySchedule(timeZone: tz, startHour: 8, endHour: 18)
        let resetAt = date(2026, 4, 6, 19, 0, timeZone: tz)
        let steps = [
            step(at: date(2026, 4, 4, 18, 0, timeZone: tz), sessionUsage: 42, sessionRemaining: 170, weeklyUsage: 73, resetAt: resetAt, label: "pre-dst-end"),
            step(at: date(2026, 4, 5, 18, 30, timeZone: tz), sessionUsage: 55, sessionRemaining: 140, weeklyUsage: 88, resetAt: resetAt, label: "post-dst-end"),
        ]

        return .init(
            name: "dst_crossing_history_and_schedule",
            description: "Replay across the Australia/Sydney DST boundary should stay deterministic.",
            tags: ["fast", "dst", "timezone"],
            schedule: schedule,
            initialData: StoreData(),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func noEmpiricalBeforeThreeWeeks() -> PacingValidationFixture {
        let tz = timeZone("UTC")
        let schedule = workdaySchedule(timeZone: tz, startHour: 9, endHour: 19)
        let resetAt1 = date(2026, 3, 15, 12, 0, timeZone: tz)
        let resetAt2 = date(2026, 3, 22, 12, 0, timeZone: tz)
        let resetAt3 = date(2026, 3, 29, 12, 0, timeZone: tz)

        let initialPolls = completedWeekSegment(windowEnd: resetAt1, utilization: 38, timeZone: tz)
            + completedWeekSegment(windowEnd: resetAt2, utilization: 44, timeZone: tz)
        let steps = [
            step(at: date(2026, 3, 27, 12, 0, timeZone: tz), sessionUsage: 20, sessionRemaining: 210, weeklyUsage: 71, resetAt: resetAt3, label: "pre-empirical-threshold"),
        ]

        return .init(
            name: "no_empirical_before_three_weeks",
            description: "Empirical weekly expectation must stay disabled until there is enough history span.",
            tags: ["fast", "weekly", "empirical"],
            schedule: schedule,
            initialData: storeData(polls: initialPolls, sessionStartIndices: [0, 3]),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [
                .init(windowEnd: resetAt2, utilization: 44),
                .init(windowEnd: resetAt1, utilization: 38),
            ],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func empiricalPoisoningNearWeekEndDetection() -> PacingValidationFixture {
        let tz = timeZone("Australia/Sydney")
        let schedule = allDaySchedule(timeZone: tz)
        let currentReset = date(2026, 4, 7, 16, 0, timeZone: tz)
        let currentPoll = date(2026, 4, 6, 18, 8, timeZone: tz)
        let currentRemaining = minutesUntil(currentReset, from: currentPoll)

        let historicalSlots = [
            date(2026, 3, 2, 14, 0, timeZone: tz),
            date(2026, 3, 9, 14, 0, timeZone: tz),
            date(2026, 3, 16, 17, 0, timeZone: tz),
            date(2026, 3, 23, 20, 0, timeZone: tz),
            date(2026, 3, 30, 20, 0, timeZone: tz),
        ]
        let historicalUsages = [60.0, 62.0, 63.0, 64.0, 65.0]

        let initialPolls = zip(historicalSlots, historicalUsages).enumerated().flatMap { index, item in
            let windowEnd = item.0
            let usage = item.1
            let sampleTime = windowEnd.addingTimeInterval(-currentRemaining * 60)
            return [
                poll(at: sampleTime.addingTimeInterval(-300), sessionUsage: 30 + Double(index), sessionRemaining: 90, weeklyUsage: max(usage - 1, 0), weeklyRemaining: currentRemaining + 5, weeklyResetAt: windowEnd),
                poll(at: sampleTime, sessionUsage: 35 + Double(index), sessionRemaining: 85, weeklyUsage: usage, weeklyRemaining: currentRemaining, weeklyResetAt: windowEnd),
            ]
        }

        let steps = [
            step(at: currentPoll, sessionUsage: 10, sessionRemaining: 112, weeklyUsage: 86, resetAt: currentReset, label: "on-pace-but-poisoned"),
        ]

        return .init(
            name: "empirical_poisoning_near_week_end_detection",
            description: "Empirical history poisoning should be detected when it creates absurd weekly pace advice near week end.",
            tags: ["fast", "weekly", "empirical", "known-bad"],
            schedule: schedule,
            initialData: storeData(polls: initialPolls, sessionStartIndices: strideIndices(count: initialPolls.count, step: 2)),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .detect([.empiricalResetBucketMismatch, .wrongDirectionOnPace]),
            expectedWeeklyHistory: [],
            onPaceTolerance: 2.0,
            onPaceDeviationLimit: 0.25
        )
    }

    private static func allDayScheduleDriftStillTracksHistory() -> PacingValidationFixture {
        let tz = timeZone("UTC")
        let schedule = allDaySchedule(timeZone: tz)
        let resetAt = date(2026, 7, 12, 0, 0, timeZone: tz)
        let remaining = 1440.0
        let sampleTime = resetAt.addingTimeInterval(-remaining * 60)

        let historicalWeeks = [
            date(2026, 5, 31, 0, 0, timeZone: tz),
            date(2026, 6, 7, 0, 0, timeZone: tz),
            date(2026, 6, 14, 0, 0, timeZone: tz),
            date(2026, 6, 21, 0, 0, timeZone: tz),
            date(2026, 6, 28, 0, 0, timeZone: tz),
            date(2026, 7, 5, 0, 0, timeZone: tz),
            date(2026, 7, 12, 0, 0, timeZone: tz),
        ]
        let initialPolls = historicalWeeks.dropLast().enumerated().flatMap { index, windowEnd in
            [
                poll(at: windowEnd.addingTimeInterval(-remaining * 60), sessionUsage: 20 + Double(index), sessionRemaining: 120, weeklyUsage: 84 + Double(index % 2), weeklyRemaining: remaining, weeklyResetAt: windowEnd),
            ]
        }

        let steps = [
            step(at: sampleTime, sessionUsage: 22, sessionRemaining: 120, weeklyUsage: 85, resetAt: resetAt, label: "aligned-all-day"),
        ]

        return .init(
            name: "all_day_schedule_drift_still_tracks_history",
            description: "A learned 0-24 schedule with aligned history should not create a bogus weekly warning on its own.",
            tags: ["fast", "weekly", "all-day"],
            schedule: schedule,
            initialData: storeData(polls: initialPolls, sessionStartIndices: strideIndices(count: initialPolls.count, step: 1)),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [],
            onPaceTolerance: 3.0,
            onPaceDeviationLimit: 0.25
        )
    }

    private static func restartSparsePollingRestoresState() -> PacingValidationFixture {
        let tz = timeZone("UTC")
        let schedule = workdaySchedule(timeZone: tz, startHour: 9, endHour: 19)
        let resetAt = date(2026, 6, 14, 12, 0, timeZone: tz)
        let initialPolls = [
            poll(at: date(2026, 6, 10, 9, 0, timeZone: tz), sessionUsage: 0, sessionRemaining: 300, weeklyUsage: 20, weeklyRemaining: minutesUntil(resetAt, from: date(2026, 6, 10, 9, 0, timeZone: tz)), weeklyResetAt: resetAt),
            poll(at: date(2026, 6, 10, 9, 5, timeZone: tz), sessionUsage: 4, sessionRemaining: 295, weeklyUsage: 21, weeklyRemaining: minutesUntil(resetAt, from: date(2026, 6, 10, 9, 5, timeZone: tz)), weeklyResetAt: resetAt),
            poll(at: date(2026, 6, 10, 9, 10, timeZone: tz), sessionUsage: 8, sessionRemaining: 290, weeklyUsage: 22, weeklyRemaining: minutesUntil(resetAt, from: date(2026, 6, 10, 9, 10, timeZone: tz)), weeklyResetAt: resetAt),
        ]
        let steps = [
            step(at: date(2026, 6, 10, 17, 45, timeZone: tz), sessionUsage: 0, sessionRemaining: 300, weeklyUsage: 25, resetAt: resetAt, label: "restart"),
            step(at: date(2026, 6, 10, 17, 50, timeZone: tz), sessionUsage: 6, sessionRemaining: 295, weeklyUsage: 26, resetAt: resetAt, label: "resumed"),
        ]

        return .init(
            name: "restart_sparse_polling_restores_state",
            description: "A restart after sparse polling should reconstitute state without duplicating history or breaking rates.",
            tags: ["fast", "restart", "sparse"],
            schedule: schedule,
            initialData: storeData(polls: initialPolls, sessionStartIndices: [0]),
            steps: steps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: [],
            onPaceTolerance: nil,
            onPaceDeviationLimit: nil
        )
    }

    private static func timeZone(_ identifier: String) -> TimeZone {
        TimeZone(identifier: identifier) ?? .gmt
    }

    private static func workdaySchedule(timeZone: TimeZone, startHour: Double, endHour: Double) -> PacingScheduleContext {
        .init(
            timeZoneIdentifier: timeZone.identifier,
            dailyWindows: Array(repeating: .init(startHour: startHour, endHour: endHour), count: 7)
        )
    }

    private static func allDaySchedule(timeZone: TimeZone) -> PacingScheduleContext {
        .init(
            timeZoneIdentifier: timeZone.identifier,
            dailyWindows: Array(repeating: .init(startHour: 0, endHour: 24), count: 7)
        )
    }

    private static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        timeZone: TimeZone
    ) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: .init(
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))!
    }

    private static func minutesUntil(_ resetAt: Date, from timestamp: Date) -> Double {
        max(resetAt.timeIntervalSince(timestamp) / 60, 0)
    }

    private static func poll(
        at timestamp: Date,
        sessionUsage: Double,
        sessionRemaining: Double,
        weeklyUsage: Double,
        weeklyRemaining: Double,
        weeklyResetAt: Date? = nil
    ) -> Poll {
        Poll(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: weeklyRemaining,
            weeklyResetAt: weeklyResetAt
        )
    }

    private static func step(
        at timestamp: Date,
        sessionUsage: Double,
        sessionRemaining: Double,
        weeklyUsage: Double,
        resetAt: Date,
        label: String? = nil
    ) -> PacingReplayStep {
        .init(
            timestamp: timestamp,
            sessionUsage: sessionUsage,
            sessionRemaining: sessionRemaining,
            weeklyUsage: weeklyUsage,
            weeklyRemaining: minutesUntil(resetAt, from: timestamp),
            weeklyResetAt: resetAt,
            label: label
        )
    }

    private static func completedWeekSegment(
        windowEnd: Date,
        utilization: Double,
        timeZone _: TimeZone
    ) -> [Poll] {
        let timestamps = [
            windowEnd.addingTimeInterval(-3 * 3600),
            windowEnd.addingTimeInterval(-90 * 60),
            windowEnd.addingTimeInterval(-5 * 60),
        ]
        let usages = [
            max(utilization - 3, 0),
            max(utilization - 1, 0),
            utilization,
        ]
        let sessionUsages = [22.0, 41.0, 63.0]
        let sessionRemaining = [180.0, 90.0, 5.0]

        return zip(zip(timestamps, usages), zip(sessionUsages, sessionRemaining)).map { outer, session in
            poll(
                at: outer.0,
                sessionUsage: session.0,
                sessionRemaining: session.1,
                weeklyUsage: outer.1,
                weeklyRemaining: minutesUntil(windowEnd, from: outer.0),
                weeklyResetAt: windowEnd
            )
        }
    }

    private static func storeData(polls: [Poll], sessionStartIndices: [Int]) -> StoreData {
        let sessions = sessionStartIndices.compactMap { index -> SessionStart? in
            guard polls.indices.contains(index) else { return nil }
            let poll = polls[index]
            return .init(
                timestamp: poll.timestamp,
                weeklyUsage: poll.weeklyUsage,
                weeklyRemaining: poll.weeklyRemaining,
                weeklyResetAt: poll.weeklyResetAt
            )
        }
        return .init(polls: polls, sessions: sessions)
    }

    private static func strideIndices(count: Int, step: Int) -> [Int] {
        stride(from: 0, to: count, by: step).map { $0 }
    }
}
