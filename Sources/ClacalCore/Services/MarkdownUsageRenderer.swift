import Foundation

public enum MarkdownUsageRenderer {
    public static func usage(_ snapshot: UsageSnapshot) -> String {
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
            "| Metric | Value | Detail |",
            "|---|---:|---|",
            row("Pace", deviation(metrics.calibrator, positive: "Ease off", negative: "Use more"), "Combined calibrator"),
        ]

        if metrics.isSessionActive {
            lines += [
                row("Session Pace", deviation(metrics.sessionDeviation, positive: "Ahead", negative: "Behind"), "Target \(wholePercent(metrics.sessionTarget))"),
                row("Session Usage", wholePercent(metrics.sessionUsagePct), "\(duration(metrics.sessionMinsLeft)) left"),
            ]
        } else {
            lines.append(row("Session", "Inactive", "No active five-hour window"))
        }

        lines += [
            row("Weekly Pace", deviation(metrics.weeklyDeviation, positive: "Ahead", negative: "Behind"), "\(duration(metrics.weeklyMinsLeft)) until reset"),
            row("Daily Budget", wholePercent(metrics.dailyBudgetRemaining * 100), "Remaining"),
            row("Weekly Usage", wholePercent(metrics.weeklyUsagePct), "\(wholePercent(metrics.weeklyElapsedPct)) of window elapsed"),
            "",
            "## Stats",
            "",
            "| Metric | Value |",
            "|---|---:|",
            statRow("Average session usage", snapshot.stats.avgSessionUsage.map(wholePercent) ?? "Not enough data"),
            statRow("Today active / total", hours(snapshot.stats.hoursToday)),
        ]

        if let weekAvg = snapshot.stats.hoursWeekAvg {
            lines.append(statRow("Week average active / total", "\(hours(weekAvg)) per day"))
        }
        if let allTimeAvg = snapshot.stats.hoursAllTimeAvg {
            lines.append(statRow("All-time average active / total", "\(hours(allTimeAvg)) per day"))
        }
        if !snapshot.stats.weeklyHistory.isEmpty {
            lines += [
                "",
                "## Weekly History",
                "",
                "| Window End | Utilization |",
                "|---|---:|",
            ]
            lines += snapshot.stats.weeklyHistory.map {
                "| \(iso8601Date($0.windowEnd)) | \(wholePercent($0.utilization)) |"
            }
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

    private static func row(_ metric: String, _ value: String, _ detail: String) -> String {
        "| \(metric) | \(value) | \(detail) |"
    }

    private static func statRow(_ metric: String, _ value: String) -> String {
        "| \(metric) | \(value) |"
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
