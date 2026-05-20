import AppKit
import SwiftUI

enum UsageColor: Sendable {
    /// Green at magnitude 0 (on pace), red at magnitude 1 (max deviation).
    static func fromCalibrator(_ calibrator: Double) -> Color {
        let magnitude = min(max(abs(calibrator), 0), 1)
        let hue = (1 - magnitude) * (120.0 / 360.0)
        return Color(hue: hue, saturation: 0.6, brightness: 0.925)
    }

    static func cgColorFromCalibrator(_ calibrator: Double) -> CGColor {
        NSColor(fromCalibrator(calibrator)).cgColor
    }
}
