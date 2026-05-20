import Foundation
import Testing
@testable import Clacal
@testable import ClacalCore

@Suite("Usage report")
@MainActor
struct UsageReportTests {
    @Test("Snapshot builder maps a fresh active API response to metrics")
    func snapshotBuilderActiveSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshotBuilder.make(
            response: UsageLimits(
                five_hour: UsageWindow(
                    utilization: 25,
                    resets_at: iso8601(now.addingTimeInterval(60 * 60))
                ),
                seven_day: UsageWindow(
                    utilization: 40,
                    resets_at: iso8601(now.addingTimeInterval(2 * 24 * 60 * 60))
                ),
                rate_limit_tier: "tier_3"
            ),
            optimiser: UsageOptimiser(),
            now: now
        )

        #expect(snapshot.metrics.sessionUsagePct == 25)
        #expect(snapshot.metrics.weeklyUsagePct == 40)
        #expect(snapshot.metrics.sessionMinsLeft == 60)
        #expect(snapshot.metrics.isSessionActive)
        #expect(snapshot.rateLimitTier == "tier_3")
    }

    @Test("Snapshot builder handles missing five-hour window as inactive session")
    func snapshotBuilderInactiveSession() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshotBuilder.make(
            response: UsageLimits(
                five_hour: nil,
                seven_day: UsageWindow(
                    utilization: 45,
                    resets_at: iso8601(now.addingTimeInterval(24 * 60 * 60))
                ),
                rate_limit_tier: nil
            ),
            optimiser: UsageOptimiser(),
            now: now
        )

        #expect(snapshot.metrics.sessionUsagePct == 0)
        #expect(snapshot.metrics.sessionMinsLeft == 0)
        #expect(!snapshot.metrics.isSessionActive)
    }

    @Test("Markdown usage output includes current usage and sparse stats")
    func markdownUsageOutput() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshotBuilder.make(
            response: UsageLimits(
                five_hour: UsageWindow(
                    utilization: 25,
                    resets_at: iso8601(now.addingTimeInterval(90 * 60))
                ),
                seven_day: UsageWindow(
                    utilization: 40,
                    resets_at: iso8601(now.addingTimeInterval(2 * 24 * 60 * 60))
                ),
                rate_limit_tier: "tier_3"
            ),
            optimiser: UsageOptimiser(),
            now: now
        )

        let markdown = MarkdownUsageRenderer.usage(snapshot)

        #expect(markdown.contains("# Clacal Usage"))
        #expect(markdown.contains("Rate limit tier: `tier_3`"))
        #expect(markdown.contains("| Session Usage | 25% | 1h 30m left |"))
        #expect(markdown.contains("| Average session usage | Not enough data |"))
    }

    @Test("Markdown usage output describes inactive sessions")
    func markdownInactiveSessionOutput() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshotBuilder.make(
            response: UsageLimits(
                five_hour: nil,
                seven_day: UsageWindow(
                    utilization: 40,
                    resets_at: iso8601(now.addingTimeInterval(24 * 60 * 60))
                ),
                rate_limit_tier: nil
            ),
            optimiser: UsageOptimiser(),
            now: now
        )

        let markdown = MarkdownUsageRenderer.usage(snapshot)

        #expect(markdown.contains("| Session | Inactive | No active five-hour window |"))
        #expect(!markdown.contains("Rate limit tier:"))
    }

    @Test("Markdown error output gives login action for missing token")
    func markdownMissingTokenError() {
        let markdown = MarkdownUsageRenderer.error(UsageReportError.missingToken)

        #expect(markdown.contains("# Clacal Error"))
        #expect(markdown.contains("Action: run `claude login`, then retry `clacal`."))
        #expect(markdown.contains("No OAuth token in Keychain"))
    }

    @Test("Markdown error output includes API error detail")
    func markdownAPIError() {
        let markdown = MarkdownUsageRenderer.error(APIError.server(status: 429, message: "rate limited"))

        #expect(markdown.contains("# Clacal Error"))
        #expect(markdown.contains("Detail: API 429: rate limited"))
    }

    @Test("Fresh reporter surfaces persistence failure")
    func freshReporterPersistenceFailure() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tempParentFile = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try Data("not a directory".utf8).write(to: tempParentFile)
        defer { try? FileManager.default.removeItem(at: tempParentFile) }

        do {
            _ = try await UsageReporter.fetchFresh(
                tokenProvider: { "token" },
                fetchUsage: { _ in
                    UsageLimits(
                        five_hour: UsageWindow(
                            utilization: 25,
                            resets_at: iso8601(now.addingTimeInterval(90 * 60))
                        ),
                        seven_day: UsageWindow(
                            utilization: 40,
                            resets_at: iso8601(now.addingTimeInterval(2 * 24 * 60 * 60))
                        ),
                        rate_limit_tier: "tier_3"
                    )
                },
                config: AppConfig(),
                dataURL: tempParentFile.appending(path: "usage_data.json"),
                now: now
            )
            Issue.record("Expected persistence failure")
        } catch {
            let markdown = MarkdownUsageRenderer.error(error)
            #expect(markdown.contains("# Clacal Error"))
            #expect(markdown.contains("Detail:"))
        }
    }

    @Test("Markdown error output includes network error detail")
    func markdownNetworkError() {
        let markdown = MarkdownUsageRenderer.error(URLError(.notConnectedToInternet))

        #expect(markdown.contains("# Clacal Error"))
        #expect(markdown.contains("Detail: Network error: notConnectedToInternet (-1009)"))
    }

    @Test("Markdown error output includes decode error detail")
    func markdownDecodeError() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad payload"))
        let markdown = MarkdownUsageRenderer.error(error)

        #expect(markdown.contains("# Clacal Error"))
        #expect(markdown.contains("Detail: Decode error: data corrupted: bad payload"))
    }

    @Test("Markdown usage output includes available stats history")
    func markdownStatsHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(
            metrics: UsageMetrics(
                sessionUsagePct: 25,
                weeklyUsagePct: 40,
                sessionMinsLeft: 90,
                weeklyMinsLeft: 2_880,
                calibrator: 0,
                sessionTarget: 100,
                sessionDeviation: 0,
                dailyDeviation: 0,
                dailyBudgetRemaining: 0.75,
                weeklyDeviation: 0,
                sessionElapsedPct: 70,
                weeklyElapsedPct: 80,
                isSessionActive: true,
                timestamp: now
            ),
            stats: UsageStats(
                avgSessionUsage: 62,
                hoursToday: .init(active: 2.5, total: 3),
                hoursWeekAvg: .init(active: 4, total: 5),
                hoursAllTimeAvg: .init(active: 3, total: 4),
                weeklyHistory: [
                    .init(windowEnd: now.addingTimeInterval(-86_400), utilization: 74),
                ]
            ),
            rateLimitTier: nil,
            generatedAt: now
        )

        let markdown = MarkdownUsageRenderer.usage(snapshot)

        #expect(markdown.contains("| Average session usage | 62% |"))
        #expect(markdown.contains("| Week average active / total | 4.0h / 5.0h per day |"))
        #expect(markdown.contains("## Weekly History"))
        #expect(markdown.contains("| Utilization |"))
        #expect(markdown.contains("| 74% |"))
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
