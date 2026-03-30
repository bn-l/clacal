import SwiftUI
import AppKit
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "CalibratorIcon")

struct CalibratorIcon: View {
    let calibrator: Double
    let sessionDeviation: Double
    let dailyDeviation: Double
    let dailyBudgetRemaining: Double
    let displayMode: MenuBarDisplayMode
    var isSessionActive = true
    var hasError = false

    var body: some View {
        if hasError {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            switch displayMode {
            case .calibrator: Image(nsImage: renderCalibrator())
            case .dualBar:    Image(nsImage: renderDualBar())
            }
        }
    }

    private func renderCalibrator() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderCalibrator: no CGContext available")
                return false
            }

            let centerY = size / 2
            let barWidth = size * 0.8
            let barX = (size - barWidth) / 2
            let maxExtent = size / 2

            let clamped = max(-1, min(1, calibrator))
            let magnitude = abs(clamped)
            let barHeight = CGFloat(magnitude) * maxExtent

            if barHeight > 0.5 {
                let color = UsageColor.cgColorFromCalibrator(calibrator)
                let barY: CGFloat = clamped >= 0 ? centerY : centerY - barHeight

                ctx.setFillColor(color)
                ctx.fill(CGRect(x: barX, y: barY, width: barWidth, height: barHeight))
            }

            // Center line
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: size, height: 1))

            // Arrow indicator when |calibrator| > 15%
            drawArrow(ctx: ctx, value: calibrator, barX: barX, barWidth: barWidth, size: size)

            return true
        }
        image.isTemplate = false
        return image
    }

    private func renderDualBar() -> NSImage {
        let size: CGFloat = 18
        let gap: CGFloat = 2
        let barWidth = (size - gap) / 2
        let centerY = size / 2
        let maxExtent = size / 2

        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            guard let ctx = NSGraphicsContext.current?.cgContext else {
                logger.error("renderDualBar: no CGContext available")
                return false
            }

            // Left bar — session deviation (positive = over-pacing, negative = under)
            if isSessionActive {
                let sClamped = max(-1, min(1, sessionDeviation))
                let sHeight = CGFloat(abs(sClamped)) * maxExtent
                if sHeight > 0.5 {
                    ctx.setFillColor(UsageColor.cgColorFromCalibrator(sClamped))
                    let barY: CGFloat = sClamped >= 0 ? centerY : centerY - sHeight
                    ctx.fill(CGRect(x: 0, y: barY, width: barWidth, height: sHeight))
                }
            }

            // Right bar — daily budget gauge (full=top/green, depletes downward toward bottom/red)
            let remaining = max(0, min(1, dailyBudgetRemaining))
            let gaugeHeight = CGFloat(remaining) * size
            if gaugeHeight > 0.5 {
                let hue = CGFloat(remaining) * (120.0 / 360.0)
                let color = NSColor(hue: hue, saturation: 0.6, brightness: 0.925, alpha: 1.0).cgColor
                ctx.setFillColor(color)
                let gaugeY = (size - gaugeHeight) / 2
                ctx.fill(CGRect(x: barWidth + gap, y: gaugeY, width: barWidth, height: gaugeHeight))
            }

            // Center line — left (session deviation) bar only
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(CGRect(x: 0, y: centerY - 0.5, width: barWidth, height: 1))

            // Arrow indicator when |sessionDeviation| > 15%
            if isSessionActive {
                drawArrow(ctx: ctx, value: sessionDeviation, barX: 0, barWidth: barWidth, size: size)
            }

            return true
        }
        image.isTemplate = false
        return image
    }

    private func drawArrow(ctx: CGContext, value: Double, barX: CGFloat, barWidth: CGFloat, size: CGFloat) {
        let clamped = max(-1, min(1, value))
        guard abs(clamped) > 0.15, abs(clamped) < 0.5 else { return }

        let arrowHeight: CGFloat = 2
        ctx.setFillColor(NSColor.white.cgColor)

        if clamped > 0 {
            // Downward arrow at bottom edge (bar is above)
            ctx.move(to: CGPoint(x: barX + barWidth / 2, y: 0))
            ctx.addLine(to: CGPoint(x: barX, y: arrowHeight))
            ctx.addLine(to: CGPoint(x: barX + barWidth, y: arrowHeight))
        } else {
            // Upward arrow at top edge (bar is below)
            ctx.move(to: CGPoint(x: barX + barWidth / 2, y: size))
            ctx.addLine(to: CGPoint(x: barX, y: size - arrowHeight))
            ctx.addLine(to: CGPoint(x: barX + barWidth, y: size - arrowHeight))
        }

        ctx.closePath()
        ctx.fillPath()
    }
}
