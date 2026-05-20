import Foundation

public enum UsageReportError: LocalizedError, Sendable, Equatable {
    case missingToken

    public var errorDescription: String? {
        switch self {
        case .missingToken:
            return "No OAuth token in Keychain. Run: claude login"
        }
    }
}

public struct UsageSnapshot: Sendable {
    public let metrics: UsageMetrics
    public let stats: UsageStats
    public let rateLimitTier: String?
    public let generatedAt: Date
}

public enum UsageReporter {
    @MainActor
    public static func fetchFresh() async throws -> UsageSnapshot {
        try await fetchFresh(
            tokenProvider: CredentialProvider.readTokenAsync,
            fetchUsage: UsageAPIClient.fetch,
            config: AppConfig.load(),
            dataURL: DataStore.defaultURL,
            now: Date()
        )
    }

    @MainActor
    static func fetchFresh(
        tokenProvider: () async -> String?,
        fetchUsage: (String) async throws -> UsageLimits,
        config: AppConfig,
        dataURL: URL,
        now: Date
    ) async throws -> UsageSnapshot {
        guard let token = await tokenProvider() else {
            throw UsageReportError.missingToken
        }

        let response = try await fetchUsage(token)
        let optimiser = UsageOptimiser(
            data: DataStore.load(from: dataURL),
            activeHoursPerDay: config.activeHoursPerDay,
            persistURL: nil
        )

        let snapshot = UsageSnapshotBuilder.make(
            response: response,
            optimiser: optimiser,
            now: now
        )
        try DataStore.saveThrowing(
            StoreData(
                polls: optimiser.polls,
                sessions: optimiser.sessionStarts,
                dailySnapshot: optimiser.dailySnapshot,
                dailyActivities: optimiser.dailyActivities
            ),
            to: dataURL
        )
        return snapshot
    }
}

@MainActor
enum UsageSnapshotBuilder {
    static func make(
        response: UsageLimits,
        optimiser: UsageOptimiser,
        now: Date
    ) -> UsageSnapshot {
        let sessionMinsLeft = UsageTimeParser.minutesUntil(response.five_hour?.resets_at, now: now)
        return make(
            sessionUsagePct: response.five_hour?.utilization ?? 0,
            weeklyUsagePct: response.seven_day?.utilization ?? 0,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: UsageTimeParser.minutesUntil(response.seven_day?.resets_at, now: now),
            weeklyResetAt: UsageTimeParser.parseISO8601Date(response.seven_day?.resets_at),
            isSessionActive: response.five_hour != nil && sessionMinsLeft > 0,
            rateLimitTier: response.rate_limit_tier,
            optimiser: optimiser,
            now: now
        )
    }

    static func make(
        sessionUsagePct: Double,
        weeklyUsagePct: Double,
        sessionMinsLeft: Double,
        weeklyMinsLeft: Double,
        weeklyResetAt: Date? = nil,
        isSessionActive: Bool = true,
        rateLimitTier: String? = nil,
        optimiser: UsageOptimiser,
        now: Date
    ) -> UsageSnapshot {
        let result = optimiser.recordPoll(
            sessionUsage: sessionUsagePct,
            sessionRemaining: sessionMinsLeft,
            weeklyUsage: weeklyUsagePct,
            weeklyRemaining: weeklyMinsLeft,
            weeklyResetAt: weeklyResetAt,
            timestamp: now
        )

        let metrics = UsageMetrics(
            sessionUsagePct: sessionUsagePct,
            weeklyUsagePct: weeklyUsagePct,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: weeklyMinsLeft,
            calibrator: result.calibrator,
            sessionTarget: result.target,
            sessionDeviation: result.sessionDeviation,
            dailyDeviation: result.dailyDeviation,
            dailyBudgetRemaining: result.dailyBudgetRemaining,
            weeklyDeviation: result.weeklyDeviation,
            sessionElapsedPct: (UsageOptimiser.sessionMinutes - sessionMinsLeft) / UsageOptimiser.sessionMinutes * 100,
            weeklyElapsedPct: (UsageOptimiser.weekMinutes - weeklyMinsLeft) / UsageOptimiser.weekMinutes * 100,
            isSessionActive: isSessionActive,
            timestamp: now
        )

        return UsageSnapshot(
            metrics: metrics,
            stats: optimiser.computeStats(now: now),
            rateLimitTier: rateLimitTier,
            generatedAt: now
        )
    }
}

enum UsageTimeParser {
    static func minutesUntil(_ isoString: String?, now: Date = Date()) -> Double {
        guard let date = parseISO8601Date(isoString) else { return 0 }
        return max(date.timeIntervalSince(now) / 60, 0)
    }

    static func parseISO8601Date(_ isoString: String?) -> Date? {
        guard let isoString else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: isoString)
    }
}
