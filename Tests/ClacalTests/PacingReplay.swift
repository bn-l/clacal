import Foundation
@testable import Clacal

enum PacingValidationFailureKind: String, Codable, Sendable, CaseIterable {
    case wrongDirectionOnPace
    case deviationOutOfBounds
    case completedWeekDropped
    case completedWeekDuplicated
    case transientArtifactCreatedWeek
    case empiricalResetBucketMismatch
    case statsWindowEndMismatch
}

struct PacingFixtureExpectation: Codable, Sendable, Equatable {
    let shouldPass: Bool
    let expectedFailureKinds: [PacingValidationFailureKind]

    static let pass = Self(shouldPass: true, expectedFailureKinds: [])

    static func detect(_ failureKinds: [PacingValidationFailureKind]) -> Self {
        .init(shouldPass: false, expectedFailureKinds: failureKinds.sorted { $0.rawValue < $1.rawValue })
    }
}

struct PacingReplayStep: Codable, Sendable, Equatable {
    let timestamp: Date
    let sessionUsage: Double
    let sessionRemaining: Double
    let weeklyUsage: Double
    let weeklyRemaining: Double
    let weeklyResetAt: Date?
    let label: String?

    init(
        timestamp: Date,
        sessionUsage: Double,
        sessionRemaining: Double,
        weeklyUsage: Double,
        weeklyRemaining: Double,
        weeklyResetAt: Date? = nil,
        label: String? = nil
    ) {
        self.timestamp = timestamp
        self.sessionUsage = sessionUsage
        self.sessionRemaining = sessionRemaining
        self.weeklyUsage = weeklyUsage
        self.weeklyRemaining = weeklyRemaining
        self.weeklyResetAt = weeklyResetAt
        self.label = label
    }
}

struct PacingHistoryExpectation: Codable, Sendable, Equatable {
    let windowEnd: Date
    let utilization: Double
}

struct PacingValidationFixture: Codable, Sendable {
    let name: String
    let description: String
    let tags: [String]
    let schedule: PacingScheduleContext
    let initialData: StoreData
    let steps: [PacingReplayStep]
    let evaluationDate: Date?
    let expectedOutcome: PacingFixtureExpectation
    let expectedWeeklyHistory: [PacingHistoryExpectation]
    let onPaceTolerance: Double?
    let onPaceDeviationLimit: Double?
}

struct PacingValidationFailure: Codable, Sendable, Hashable {
    let kind: PacingValidationFailureKind
    let message: String
    let stepIndex: Int?
    let timestamp: Date?
}

struct PacingReplayObservation: Codable, Sendable, Equatable {
    let stepIndex: Int
    let label: String?
    let timestamp: Date
    let weeklyUsage: Double
    let weeklyRemaining: Double
    let weeklyElapsedPct: Double
    let target: Double
    let optimalRate: Double
    let currentRate: Double?
    let weeklyDeviation: Double
    let calibrator: Double
    let sessionDeviation: Double
    let dailyDeviation: Double
    let dailyBudgetRemaining: Double
    let exchangeRate: Double?
    let debug: PacingDecisionBreakdown
}

struct PacingReplayResult: Codable, Sendable {
    let fixture: PacingValidationFixture
    let observations: [PacingReplayObservation]
    let weeklyHistory: [PacingHistoryEntry]
    let weeklySegments: [PacingWeeklyWindowSegment]
    let debugState: PacingOptimiserDebugState
    let failures: [PacingValidationFailure]

    var failureKinds: [PacingValidationFailureKind] {
        Array(Set(failures.map(\.kind))).sorted { $0.rawValue < $1.rawValue }
    }

    var matchesExpectation: Bool {
        if fixture.expectedOutcome.shouldPass {
            return failures.isEmpty
        }
        return failureKinds == fixture.expectedOutcome.expectedFailureKinds
    }
}

@MainActor
enum PacingReplayRunner {
    static func run(_ fixture: PacingValidationFixture) -> PacingReplayResult {
        let optimiser = UsageOptimiser(
            data: fixture.initialData,
            activeHoursPerDay: fixture.schedule.dailyWindows.map { max($0.endHour - $0.startHour, 0) },
            persistURL: nil,
            timeZone: fixture.schedule.timeZone,
            detectedWindows: fixture.schedule.dailyWindows.map { (start: $0.startHour, end: $0.endHour) }
        )

        var observations: [PacingReplayObservation] = []
        for (index, step) in fixture.steps.enumerated() {
            let result = optimiser.recordPoll(
                sessionUsage: step.sessionUsage,
                sessionRemaining: step.sessionRemaining,
                weeklyUsage: step.weeklyUsage,
                weeklyRemaining: step.weeklyRemaining,
                weeklyResetAt: step.weeklyResetAt,
                timestamp: step.timestamp
            )
            guard let decision = optimiser.lastDecisionBreakdown else {
                preconditionFailure("recordPoll must populate lastDecisionBreakdown")
            }
            observations.append(
                .init(
                    stepIndex: index,
                    label: step.label,
                    timestamp: step.timestamp,
                    weeklyUsage: step.weeklyUsage,
                    weeklyRemaining: step.weeklyRemaining,
                    weeklyElapsedPct: (PacingKernelConstants.weekMinutes - step.weeklyRemaining) / PacingKernelConstants.weekMinutes * 100,
                    target: result.target,
                    optimalRate: result.optimalRate,
                    currentRate: result.currentRate,
                    weeklyDeviation: result.weeklyDeviation,
                    calibrator: result.calibrator,
                    sessionDeviation: result.sessionDeviation,
                    dailyDeviation: result.dailyDeviation,
                    dailyBudgetRemaining: result.dailyBudgetRemaining,
                    exchangeRate: result.exchangeRate,
                    debug: decision
                )
            )
        }

        let referenceDate = fixture.evaluationDate
            ?? fixture.steps.last?.timestamp
            ?? fixture.initialData.polls.last?.timestamp
            ?? Date()
        let stats = optimiser.computeStats(now: referenceDate)
        let weeklyHistory = stats.weeklyHistory.map {
            PacingHistoryEntry(windowEnd: $0.windowEnd, utilization: $0.utilization)
        }
        let debugState = optimiser.debugState()
        let weeklySegments = PacingKernel.weeklyWindowSegments(polls: debugState.polls)
        let failures = validate(
            fixture: fixture,
            observations: observations,
            weeklyHistory: weeklyHistory,
            weeklySegments: weeklySegments
        )

        return .init(
            fixture: fixture,
            observations: observations,
            weeklyHistory: weeklyHistory,
            weeklySegments: weeklySegments,
            debugState: debugState,
            failures: failures
        )
    }

    private static func validate(
        fixture: PacingValidationFixture,
        observations: [PacingReplayObservation],
        weeklyHistory: [PacingHistoryEntry],
        weeklySegments: [PacingWeeklyWindowSegment]
    ) -> [PacingValidationFailure] {
        var failures: [PacingValidationFailure] = []

        for observation in observations {
            let values = [
                observation.weeklyDeviation,
                observation.calibrator,
                observation.sessionDeviation,
                observation.dailyDeviation,
            ]
            if values.contains(where: { $0 < -1.000001 || $0 > 1.000001 }) {
                failures.append(
                    .init(
                        kind: .deviationOutOfBounds,
                        message: "Deviation escaped bounds at step \(observation.stepIndex)",
                        stepIndex: observation.stepIndex,
                        timestamp: observation.timestamp
                    )
                )
            }

            if observation.debug.weekly.source == .empirical,
               observation.debug.weekly.empiricalDiagnostics.bucketMismatch {
                failures.append(
                    .init(
                        kind: .empiricalResetBucketMismatch,
                        message: "Empirical expectation mixed reset buckets at step \(observation.stepIndex)",
                        stepIndex: observation.stepIndex,
                        timestamp: observation.timestamp
                    )
                )
            }

            if let tolerance = fixture.onPaceTolerance,
               let deviationLimit = fixture.onPaceDeviationLimit {
                let scheduleGap = observation.weeklyUsage - observation.debug.weekly.scheduleExpectedUsage
                if abs(scheduleGap) <= tolerance, abs(observation.weeklyDeviation) > deviationLimit {
                    failures.append(
                        .init(
                            kind: .wrongDirectionOnPace,
                            message: "Weekly pace overstated on a near-parity poll at step \(observation.stepIndex)",
                            stepIndex: observation.stepIndex,
                            timestamp: observation.timestamp
                        )
                    )
                }
            }
        }

        let distinctWindowEnds = Set(weeklyHistory.map { roundedWindowEnd($0.windowEnd) })
        if distinctWindowEnds.count != weeklyHistory.count {
            failures.append(
                .init(
                    kind: .completedWeekDuplicated,
                    message: "Completed weekly history contains duplicate window ends",
                    stepIndex: nil,
                    timestamp: weeklyHistory.first?.windowEnd
                )
            )
        }

        if !fixture.expectedWeeklyHistory.isEmpty {
            let expected = fixture.expectedWeeklyHistory
            for item in expected {
                guard let actual = weeklyHistory.first(where: { matchesWindowEnd($0.windowEnd, item.windowEnd) }) else {
                    failures.append(
                        .init(
                            kind: .completedWeekDropped,
                            message: "Missing completed week ending \(item.windowEnd)",
                            stepIndex: nil,
                            timestamp: item.windowEnd
                        )
                    )
                    continue
                }
                if abs(actual.utilization - item.utilization) > 0.5 {
                    failures.append(
                        .init(
                            kind: .statsWindowEndMismatch,
                            message: "Utilization mismatch for window ending \(item.windowEnd)",
                            stepIndex: nil,
                            timestamp: item.windowEnd
                        )
                    )
                }
            }

            for item in weeklyHistory where !expected.contains(where: { matchesWindowEnd($0.windowEnd, item.windowEnd) }) {
                failures.append(
                    .init(
                        kind: .transientArtifactCreatedWeek,
                        message: "Unexpected completed week ending \(item.windowEnd)",
                        stepIndex: nil,
                        timestamp: item.windowEnd
                    )
                )
            }
        }

        if weeklySegments.contains(where: { $0.pollCount < 0 }) {
            failures.append(
                .init(
                    kind: .statsWindowEndMismatch,
                    message: "Weekly segment validation encountered invalid poll counts",
                    stepIndex: nil,
                    timestamp: nil
                )
            )
        }

        return Array(Set(failures)).sorted {
            if $0.kind == $1.kind {
                return ($0.stepIndex ?? -1) < ($1.stepIndex ?? -1)
            }
            return $0.kind.rawValue < $1.kind.rawValue
        }
    }

    private static func roundedWindowEnd(_ date: Date) -> Int64 {
        Int64(date.timeIntervalSince1970.rounded())
    }

    private static func matchesWindowEnd(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= PacingKernelConstants.weeklyResetTolerance
    }
}
