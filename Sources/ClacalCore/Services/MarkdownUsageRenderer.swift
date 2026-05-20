import Foundation

public enum MarkdownUsageRenderer {
    public static func usage(
        _ snapshot: UsageSnapshot,
        includeStats: Bool = false,
        includeHistory: Bool = false
    ) -> String {
        let metrics = snapshot.metrics
        var lines = [
            "# Clacal Usage",
            "",
            "Generated: `\(iso8601(snapshot.generatedAt))`",
        ]

        if let rateLimitTier = snapshot.rateLimitTier {
            lines.append("Rate limit tier: `\(rateLimitTier)`")
        }

        lines += [
            "",
            "## Current Usage",
            "",
            bullet(
                "Pace",
                deviation(metrics.calibrator, positive: "Ease off", negative: "Use more"),
                detail: "combined calibrator"
            ),
        ]

        if metrics.isSessionActive {
            lines += [
                bullet(
                    "Session",
                    deviation(metrics.sessionDeviation, positive: "Ahead", negative: "Behind"),
                    detail: "\(wholePercent(metrics.sessionUsagePct)) used, target \(wholePercent(metrics.sessionTarget)), \(duration(metrics.sessionMinsLeft)) left"
                ),
            ]
        } else {
            lines.append(bullet("Session", "Inactive", detail: "no active five-hour window"))
        }

        lines += [
            bullet(
                "Week",
                deviation(metrics.weeklyDeviation, positive: "Ahead", negative: "Behind"),
                detail: "\(wholePercent(metrics.weeklyUsagePct)) used, \(wholePercent(metrics.weeklyElapsedPct)) elapsed, resets in \(duration(metrics.weeklyMinsLeft))"
            ),
            bullet("Daily budget", "\(wholePercent(metrics.dailyBudgetRemaining * 100)) remaining"),
        ]

        if includeStats {
            lines += statsLines(snapshot.stats)
        }

        if includeHistory {
            lines += historyLines(snapshot.stats.weeklyHistory)
        }

        return lines.joined(separator: "\n") + "\n"
    }

    public static func error(_ error: Error) -> String {
        var lines = [
            "# Clacal Error",
            "",
            "**Unable to fetch usage.**",
            "",
        ]

        if let reportError = error as? UsageReportError, reportError == .missingToken {
            lines += [
                "Action: run `claude login`, then retry `clacal`.",
                "",
            ]
        }

        lines += [
            "Detail: \(detail(for: error))",
        ]

        return lines.joined(separator: "\n") + "\n"
    }

    private static func detail(for error: Error) -> String {
        if let urlError = error as? URLError {
            return "Network error: \(urlErrorName(urlError.code)) (\(urlError.errorCode))"
        }

        switch error {
        case DecodingError.dataCorrupted(let context):
            return "Decode error: data corrupted\(debugDescriptionSuffix(context.debugDescription))"
        case DecodingError.keyNotFound(let key, let context):
            return "Decode error: missing key `\(key.stringValue)`\(debugDescriptionSuffix(context.debugDescription))"
        case DecodingError.typeMismatch(let type, let context):
            return "Decode error: expected \(type)\(debugDescriptionSuffix(context.debugDescription))"
        case DecodingError.valueNotFound(let type, let context):
            return "Decode error: missing \(type)\(debugDescriptionSuffix(context.debugDescription))"
        default:
            return error.localizedDescription
        }
    }

    private static func urlErrorName(_ code: URLError.Code) -> String {
        switch code {
        case .notConnectedToInternet:
            "notConnectedToInternet"
        case .timedOut:
            "timedOut"
        case .cannotFindHost:
            "cannotFindHost"
        case .cannotConnectToHost:
            "cannotConnectToHost"
        case .networkConnectionLost:
            "networkConnectionLost"
        case .secureConnectionFailed:
            "secureConnectionFailed"
        case .badServerResponse:
            "badServerResponse"
        default:
            "URLError"
        }
    }

    private static func debugDescriptionSuffix(_ debugDescription: String) -> String {
        debugDescription.isEmpty ? "" : ": \(debugDescription)"
    }

    private static func statsLines(_ stats: UsageStats) -> [String] {
        var lines = [
            "",
            "## Stats",
            "",
            bullet("Average session usage", stats.avgSessionUsage.map(wholePercent) ?? "Not enough data"),
            bullet("Today active / total", hours(stats.hoursToday)),
        ]

        if let weekAvg = stats.hoursWeekAvg {
            lines.append(bullet("Week average active / total", "\(hours(weekAvg)) per day"))
        }
        if let allTimeAvg = stats.hoursAllTimeAvg {
            lines.append(bullet("All-time average active / total", "\(hours(allTimeAvg)) per day"))
        }

        return lines
    }

    private static func historyLines(_ weeklyHistory: [UsageStats.WeeklyEntry]) -> [String] {
        var lines = [
            "",
            "## Weekly History",
            "",
        ]

        guard !weeklyHistory.isEmpty else {
            lines.append(bullet("Weekly history", "Not enough data"))
            return lines
        }

        lines += weeklyHistory.map {
            bullet(iso8601Date($0.windowEnd), wholePercent($0.utilization), detail: "utilization")
        }
        return lines
    }

    private static func bullet(_ label: String, _ value: String, detail: String? = nil) -> String {
        if let detail, !detail.isEmpty {
            return "- \(label): \(value) - \(detail)"
        }
        return "- \(label): \(value)"
    }

    private static func deviation(_ value: Double, positive: String, negative: String) -> String {
        let label: String
        if abs(value) < 0.1 {
            label = "On pace"
        } else {
            label = value > 0 ? positive : negative
        }
        return "\(label) \(signedPercent(value * 100))"
    }

    private static func signedPercent(_ value: Double) -> String {
        let rounded = Int(round(value))
        if rounded == 0 { return "0%" }
        return rounded > 0 ? "+\(rounded)%" : "\(rounded)%"
    }

    private static func wholePercent(_ value: Double) -> String {
        "\(Int(round(value)))%"
    }

    private static func duration(_ minutes: Double) -> String {
        let totalMinutes = max(Int(minutes), 0)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let mins = totalMinutes % 60
        if days > 0 { return "\(days)d \(hours)h \(mins)m" }
        return "\(hours)h \(mins)m"
    }

    private static func hours(_ pair: UsageStats.HoursPair) -> String {
        "\(String(format: "%.1f", pair.active))h / \(String(format: "%.1f", pair.total))h"
    }

    private static func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func iso8601Date(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
