import SwiftUI
import AppKit

struct UsageMetrics: Sendable {
    let sessionUsagePct: Double
    let weeklyUsagePct: Double
    let sessionMinsLeft: Double
    let weeklyMinsLeft: Double
    let calibrator: Double
    let sessionTarget: Double
    let sessionUtilRatio: Double
    let dailyAllotmentRatio: Double
    let timestamp: Date

    var color: Color { UsageColor.fromCalibrator(calibrator) }
    var cgColor: CGColor { NSColor(color).cgColor }
}

enum UsageColor: Sendable {
    /// Green at magnitude 0 (on pace), red at magnitude 1 (max deviation)
    static func fromCalibrator(_ calibrator: Double) -> Color {
        let magnitude = min(max(abs(calibrator), 0), 1)
        let hue = (1 - magnitude) * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.6, brightness: 0.925)
    }

    static func cgColorFromCalibrator(_ calibrator: Double) -> CGColor {
        NSColor(fromCalibrator(calibrator)).cgColor
    }

    /// Bar 1: green at 1 (on pace), red at 0 (underutilized)
    static func fromRatio(_ ratio: Double) -> Color {
        let clamped = min(max(ratio, 0), 1)
        let hue = clamped * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.6, brightness: 0.925)
    }

    static func cgColorFromRatio(_ ratio: Double) -> CGColor {
        NSColor(fromRatio(ratio)).cgColor
    }

    /// Bar 2: green at 0 (headroom), red at 1 (allotment exhausted)
    static func fromRatioInverted(_ ratio: Double) -> Color {
        let clamped = min(max(ratio, 0), 1)
        let hue = (1 - clamped) * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.6, brightness: 0.925)
    }

    static func cgColorFromRatioInverted(_ ratio: Double) -> CGColor {
        NSColor(fromRatioInverted(ratio)).cgColor
    }
}
