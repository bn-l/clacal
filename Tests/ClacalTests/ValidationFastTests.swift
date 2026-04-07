import Foundation
import Testing
@testable import Clacal

@Suite("ValidationFast — Kernel")
struct ValidationFastKernelTests {
    @Test("Weekly breakdown stays neutral when usage matches schedule")
    func weeklyBreakdownOnSchedule() {
        let schedule = PacingScheduleContext(
            timeZoneIdentifier: "UTC",
            dailyWindows: Array(repeating: .init(startHour: 0, endHour: 24), count: 7)
        )
        let resetAt = validationDate(2026, 4, 13, 0, 0, timeZone: .gmt)
        let timestamp = resetAt.addingTimeInterval(-5040 * 60)
        let poll = PacingPollSample(
            timestamp: timestamp,
            sessionUsage: 10,
            sessionRemaining: 120,
            weeklyUsage: 50,
            weeklyRemaining: 5040,
            weeklyResetAt: resetAt
        )

        let breakdown = PacingKernel.weeklyBreakdown(
            current: poll,
            history: [],
            schedule: schedule,
            dataWeeks: 0
        )

        #expect(breakdown.source == .schedule)
        #expect(approxEqual(breakdown.expectedUsage, 50))
        #expect(approxEqual(breakdown.scheduleExpectedUsage, 50))
        #expect(approxEqual(breakdown.projectedFinalUsage ?? 0, 100))
        #expect(approxEqual(breakdown.activeElapsedHours, 84))
        #expect(approxEqual(breakdown.activeTotalHours, 168))
        #expect(approxEqual(breakdown.finalDeviation, 0))
    }

    @Test("Budget-limited optimal rate uses exchange rate")
    func budgetLimitedOptimalRate() {
        let poll = PacingPollSample(
            timestamp: validationDate(2026, 4, 8, 12, 0, timeZone: .gmt),
            sessionUsage: 20,
            sessionRemaining: 200,
            weeklyUsage: 60,
            weeklyRemaining: 1000,
            weeklyResetAt: validationDate(2026, 4, 9, 4, 40, timeZone: .gmt)
        )

        let budget = PacingKernel.sessionBudget(
            current: poll,
            exchangeRate: 0.5,
            remainingActiveHours: 10
        )
        let optimal = PacingKernel.optimalRate(
            current: poll,
            target: 80,
            sessionBudget: budget
        )

        #expect(budget != nil)
        #expect(approxEqual(budget?.budget ?? 0, 20))
        #expect(approxEqual(optimal.targetRate, 0.3))
        #expect(approxEqual(optimal.ceilingRate, 0.4))
        #expect(approxEqual(optimal.budgetRate ?? 0, 0.2))
        #expect(approxEqual(optimal.optimalRate, 0.2))
    }

    @Test("Calibrator breakdown preserves PB plus hysteresis math")
    func calibratorBreakdown() {
        let poll = PacingPollSample(
            timestamp: validationDate(2026, 4, 8, 12, 0, timeZone: .gmt),
            sessionUsage: 40,
            sessionRemaining: 150,
            weeklyUsage: 80,
            weeklyRemaining: 1440,
            weeklyResetAt: validationDate(2026, 4, 9, 12, 0, timeZone: .gmt)
        )

        let breakdown = PacingKernel.calibrator(
            previousState: .init(zone: .ok, previousOutput: 0),
            sessionError: 0.4,
            weeklyDeviation: 0.8,
            current: poll
        )

        #expect(breakdown.updatedState.zone == .fast)
        #expect(approxEqual(breakdown.rawBlend, 0.6))
        #expect(approxEqual(breakdown.deadZoned, 0.5789473684, tolerance: 0.00001))
        #expect(approxEqual(breakdown.smoothedOutput, 0.1447368421, tolerance: 0.00001))
    }

    @Test("Active hours remain clock-stable across Sydney DST end")
    func activeHoursAcrossDSTEnd() {
        let tz = TimeZone(identifier: "Australia/Sydney")!
        let schedule = PacingScheduleContext(
            timeZoneIdentifier: tz.identifier,
            dailyWindows: Array(repeating: .init(startHour: 8, endHour: 18), count: 7)
        )
        let start = validationDate(2026, 4, 4, 0, 0, timeZone: tz)
        let end = validationDate(2026, 4, 6, 0, 0, timeZone: tz)

        let hours = PacingKernel.activeHoursInRange(from: start, to: end, schedule: schedule)
        #expect(approxEqual(hours, 20))
    }
}

@Suite("ValidationFast — Replay")
@MainActor
struct ValidationFastReplayTests {
    @Test("Named fixtures match their expected outcomes")
    func namedFixturesMatchExpectations() {
        let results = PacingFixtureLibrary.allFixtures().map(PacingReplayRunner.run)
        #expect(results.filter { !$0.matchesExpectation }.isEmpty)
    }

    @Test("Schedule source is used before empirical history threshold")
    func noEmpiricalBeforeThreshold() throws {
        let fixture = try #require(PacingFixtureLibrary.fixture(named: "no_empirical_before_three_weeks"))
        let result = PacingReplayRunner.run(fixture)
        let final = try #require(result.observations.last)

        #expect(final.debug.weekly.source == .schedule)
        #expect(result.matchesExpectation)
    }

    @Test("Reset bridge fixture retains the completed 97 percent week")
    func resetBridgeRetainsCompletedWeek() throws {
        let fixture = try #require(PacingFixtureLibrary.fixture(named: "reset_bridge_keeps_completed_97pct_week"))
        let result = PacingReplayRunner.run(fixture)
        let first = try #require(result.weeklyHistory.first)

        #expect(result.matchesExpectation)
        #expect(approxEqual(first.utilization, 97))
        #expect(abs(first.windowEnd.timeIntervalSince(validationDate(2026, 3, 29, 20, 0, timeZone: TimeZone(identifier: "Australia/Sydney")!))) <= 60)
    }

    @Test("Known-bad empirical poisoning is detected")
    func empiricalPoisoningIsDetected() throws {
        let fixture = try #require(PacingFixtureLibrary.fixture(named: "empirical_poisoning_near_week_end_detection"))
        let result = PacingReplayRunner.run(fixture)
        let final = try #require(result.observations.last)

        #expect(result.failureKinds == [.empiricalResetBucketMismatch, .wrongDirectionOnPace])
        #expect(final.debug.weekly.source == .empirical)
        #expect(final.weeklyDeviation > 0.9)
        #expect(result.matchesExpectation)
    }
}

@Suite("ValidationFast — Reporting")
@MainActor
struct ValidationFastReportingTests {
    @Test("Replay report writer exports summary and fixture payloads")
    func reportWriterExportsArtifacts() throws {
        let fixtures = Array(PacingFixtureLibrary.allFixtures().prefix(2))
        let results = fixtures.map(PacingReplayRunner.run)
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "clacal-validation-\(UUID().uuidString)", directoryHint: .isDirectory)

        try PacingReportWriter.writeReplayResults(results, to: directory)

        #expect(FileManager.default.fileExists(atPath: directory.appending(path: "summary.md").path))
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path).filter { $0.hasSuffix(".json") }.count) == results.count)
    }
}

private func validationDate(
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
