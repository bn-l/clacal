import Foundation

enum PacingUsageProfile: String, Codable, Sendable, CaseIterable {
    case onPace
    case frontLoaded
    case lateBurst
    case bursty
}

enum PacingArtifactProfile: String, Codable, Sendable, CaseIterable {
    case clean
    case zeroPlateauReset
    case placeholder
    case midWeekZeroRecovery
    case resetDrift
}

enum PacingCadenceProfile: String, Codable, Sendable, CaseIterable {
    case stable
    case jittered
    case sparse
}

enum PacingLearningProfile: String, Codable, Sendable, CaseIterable {
    case configuredWorkday
    case learnedAllDay
}

enum PacingEmpiricalProfile: String, Codable, Sendable, CaseIterable {
    case none
    case aligned
    case poisoned
}

struct PacingSweepScenarioDescriptor: Codable, Sendable {
    let usage: PacingUsageProfile
    let artifact: PacingArtifactProfile
    let cadence: PacingCadenceProfile
    let learning: PacingLearningProfile
    let empirical: PacingEmpiricalProfile
    let timeZoneIdentifier: String
}

struct PacingSweepResult: Codable, Sendable {
    let seed: UInt64
    let scenarioCount: Int
    let failureCount: Int
    let failed: [PacingReplayResult]
}

@MainActor
enum PacingSweepRunner {
    static func scenarios(seed: UInt64 = 20_260_407) -> [PacingValidationFixture] {
        let timeZones = [
            TimeZone(identifier: "UTC")!,
            TimeZone(identifier: "Australia/Sydney")!,
            TimeZone(identifier: "America/New_York")!,
        ]

        return timeZones.flatMap { timeZone in
            PacingUsageProfile.allCases.flatMap { usage in
                PacingArtifactProfile.allCases.flatMap { artifact in
                    PacingCadenceProfile.allCases.flatMap { cadence in
                        PacingLearningProfile.allCases.flatMap { learning in
                            PacingEmpiricalProfile.allCases.map { empirical in
                                makeScenario(
                                    descriptor: .init(
                                        usage: usage,
                                        artifact: artifact,
                                        cadence: cadence,
                                        learning: learning,
                                        empirical: empirical,
                                        timeZoneIdentifier: timeZone.identifier
                                    ),
                                    seed: seed
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    static func run(seed: UInt64 = 20_260_407) -> PacingSweepResult {
        let results = scenarios(seed: seed).map(PacingReplayRunner.run)
        let failed = results.filter { !$0.matchesExpectation }
        return .init(
            seed: seed,
            scenarioCount: results.count,
            failureCount: failed.count,
            failed: failed
        )
    }

    private static func makeScenario(
        descriptor: PacingSweepScenarioDescriptor,
        seed: UInt64
    ) -> PacingValidationFixture {
        var generator = SeededGenerator(seed: seed ^ descriptorHash(descriptor))
        let timeZone = TimeZone(identifier: descriptor.timeZoneIdentifier) ?? .gmt
        let schedule = switch descriptor.learning {
        case .configuredWorkday:
            PacingScheduleContext(
                timeZoneIdentifier: timeZone.identifier,
                dailyWindows: Array(repeating: .init(startHour: 9, endHour: 19), count: 7)
            )
        case .learnedAllDay:
            PacingScheduleContext(
                timeZoneIdentifier: timeZone.identifier,
                dailyWindows: Array(repeating: .init(startHour: 0, endHour: 24), count: 7)
            )
        }

        let baseResetAt = makeDate(2026, 9, 7, 12, 0, timeZone: timeZone)
        let currentResetAt = shiftedReset(base: baseResetAt, descriptor: descriptor, weekIndex: 0)
        let weekStart = currentResetAt.addingTimeInterval(-PacingKernelConstants.weekMinutes * 60)
        let fractions: [Double] = switch descriptor.cadence {
        case .stable: [0.12, 0.35, 0.58, 0.79, 0.87]
        case .jittered: [0.12, 0.33, 0.57, 0.81, 0.87]
        case .sparse: [0.20, 0.52, 0.87]
        }

        var stepTimes = fractions.map { fraction in
            weekStart.addingTimeInterval(PacingKernelConstants.weekMinutes * 60 * fraction)
        }
        if descriptor.cadence == .jittered {
            stepTimes = stepTimes.map {
                $0.addingTimeInterval(Double.random(in: -420...420, using: &generator))
            }
        }
        stepTimes.sort()

        let steps = stepTimes.enumerated().map { index, timestamp in
            let expected = scheduleExpected(
                at: timestamp,
                resetAt: currentResetAt,
                schedule: schedule
            )
            let weeklyUsage = usageValue(
                expected: expected,
                progress: Double(index + 1) / Double(stepTimes.count),
                profile: descriptor.usage,
                generator: &generator
            )
            return PacingReplayStep(
                timestamp: timestamp,
                sessionUsage: max(0, min(100, weeklyUsage / 2.8)),
                sessionRemaining: max(300 - Double(index * 45), 30),
                weeklyUsage: weeklyUsage,
                weeklyRemaining: max(currentResetAt.timeIntervalSince(timestamp) / 60, 0),
                weeklyResetAt: currentResetAt,
                label: "\(descriptor.usage.rawValue)-\(index)"
            )
        }

        let historicalWeeks = descriptor.empirical == .none ? 2 : 5
        var historyPolls: [Poll] = []
        var sessionStartIndices: [Int] = []
        var expectedWeeklyHistory: [PacingHistoryExpectation] = []
        let empiricalReferenceTime = stepTimes.last ?? weekStart.addingTimeInterval(PacingKernelConstants.weekMinutes * 60 * 0.87)
        let empiricalReferenceRemaining = max(currentResetAt.timeIntervalSince(empiricalReferenceTime) / 60, 0)

        for weekIndex in 1...historicalWeeks {
            let resetAt = shiftedReset(base: baseResetAt, descriptor: descriptor, weekIndex: weekIndex)
            let utilization = historicalUtilization(profile: descriptor, weekIndex: weekIndex)
            sessionStartIndices.append(historyPolls.count)
            historyPolls += completedWeekSegment(windowEnd: resetAt, utilization: utilization, schedule: schedule)
            if descriptor.empirical != .none {
                let probeUsage = switch descriptor.empirical {
                case .none, .aligned:
                    utilization
                case .poisoned:
                    max(utilization - 18, 0)
                }
                historyPolls.append(
                    Poll(
                        timestamp: resetAt.addingTimeInterval(-empiricalReferenceRemaining * 60),
                        sessionUsage: 32,
                        sessionRemaining: 95,
                        weeklyUsage: probeUsage,
                        weeklyRemaining: empiricalReferenceRemaining,
                        weeklyResetAt: resetAt
                    )
                )
            }
            expectedWeeklyHistory.append(.init(windowEnd: resetAt, utilization: utilization))
        }

        if descriptor.artifact == .placeholder, let midpoint = stepTimes.dropLast().last {
            historyPolls.append(
                Poll(
                    timestamp: midpoint.addingTimeInterval(-3 * 86400),
                    sessionUsage: 10,
                    sessionRemaining: 280,
                    weeklyUsage: 20,
                    weeklyRemaining: 8000
                )
            )
        }

        var replaySteps = steps
        if descriptor.artifact == .midWeekZeroRecovery, replaySteps.count >= 3 {
            let zeroTime = replaySteps[1].timestamp.addingTimeInterval(180)
            replaySteps.insert(
                .init(
                    timestamp: zeroTime,
                    sessionUsage: 0,
                    sessionRemaining: 0,
                    weeklyUsage: 0,
                    weeklyRemaining: 0,
                    weeklyResetAt: nil,
                    label: "midweek-zero"
                ),
                at: 2
            )
        }
        if descriptor.artifact == .zeroPlateauReset, let final = replaySteps.last {
            let completedUsage = min(final.weeklyUsage + 8, 99)
            let zeroTime = currentResetAt.addingTimeInterval(120)
            replaySteps = Array(replaySteps.dropLast()) + [
                .init(
                    timestamp: currentResetAt.addingTimeInterval(-120),
                    sessionUsage: 70,
                    sessionRemaining: 2,
                    weeklyUsage: completedUsage,
                    weeklyRemaining: 2,
                    weeklyResetAt: currentResetAt,
                    label: "final-good"
                ),
                .init(
                    timestamp: zeroTime,
                    sessionUsage: 0,
                    sessionRemaining: 0,
                    weeklyUsage: 0,
                    weeklyRemaining: 0,
                    weeklyResetAt: currentResetAt,
                    label: "reset-zero"
                ),
                .init(
                    timestamp: zeroTime.addingTimeInterval(600),
                    sessionUsage: 0,
                    sessionRemaining: 300,
                    weeklyUsage: 0,
                    weeklyRemaining: PacingKernelConstants.weekMinutes - 10,
                    weeklyResetAt: currentResetAt.addingTimeInterval(PacingKernelConstants.weekMinutes * 60),
                    label: "new-window"
                ),
            ]
            expectedWeeklyHistory.insert(.init(windowEnd: currentResetAt, utilization: completedUsage), at: 0)
        }

        expectedWeeklyHistory.sort { $0.windowEnd > $1.windowEnd }

        return .init(
            name: "sweep_\(descriptor.timeZoneIdentifier.replacingOccurrences(of: "/", with: "_"))_\(descriptor.usage.rawValue)_\(descriptor.artifact.rawValue)_\(descriptor.cadence.rawValue)_\(descriptor.learning.rawValue)_\(descriptor.empirical.rawValue)",
            description: "Generated sweep scenario for \(descriptor.timeZoneIdentifier) / \(descriptor.usage.rawValue) / \(descriptor.artifact.rawValue).",
            tags: ["sweep", descriptor.usage.rawValue, descriptor.artifact.rawValue, descriptor.timeZoneIdentifier],
            schedule: schedule,
            initialData: .init(polls: historyPolls, sessions: sessionStartIndices.compactMap { index in
                guard historyPolls.indices.contains(index) else { return nil }
                let poll = historyPolls[index]
                return .init(
                    timestamp: poll.timestamp,
                    weeklyUsage: poll.weeklyUsage,
                    weeklyRemaining: poll.weeklyRemaining,
                    weeklyResetAt: poll.weeklyResetAt
                )
            }),
            steps: replaySteps,
            evaluationDate: nil,
            expectedOutcome: .pass,
            expectedWeeklyHistory: expectedWeeklyHistory,
            onPaceTolerance: descriptor.usage == .onPace ? 4.0 : nil,
            onPaceDeviationLimit: descriptor.usage == .onPace ? 0.30 : nil
        )
    }

    private static func shiftedReset(
        base: Date,
        descriptor: PacingSweepScenarioDescriptor,
        weekIndex: Int
    ) -> Date {
        let baseShift = TimeInterval(-weekIndex) * PacingKernelConstants.weekMinutes * 60
        let driftHours: Double = switch descriptor.artifact {
        case .resetDrift:
            Double((weekIndex % 4) * 2)
        default:
            0
        }
        return base.addingTimeInterval(baseShift + driftHours * 3600)
    }

    private static func descriptorHash(_ descriptor: PacingSweepScenarioDescriptor) -> UInt64 {
        [
            descriptor.usage.rawValue,
            descriptor.artifact.rawValue,
            descriptor.cadence.rawValue,
            descriptor.learning.rawValue,
            descriptor.empirical.rawValue,
            descriptor.timeZoneIdentifier,
        ]
        .joined(separator: "|")
        .utf8
        .reduce(14_695_981_039_346_656_037 as UInt64) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    private static func historicalUtilization(
        profile descriptor: PacingSweepScenarioDescriptor,
        weekIndex: Int
    ) -> Double {
        switch descriptor.empirical {
        case .none, .aligned:
            return switch descriptor.usage {
            case .onPace: 82 + Double(weekIndex % 2)
            case .frontLoaded: 90 - Double(weekIndex)
            case .lateBurst: 68 + Double(weekIndex)
            case .bursty: 74 + Double((weekIndex * 3) % 9)
            }
        case .poisoned:
            return 58 + Double(weekIndex)
        }
    }

    private static func scheduleExpected(
        at timestamp: Date,
        resetAt: Date,
        schedule: PacingScheduleContext
    ) -> Double {
        let weekStart = resetAt.addingTimeInterval(-PacingKernelConstants.weekMinutes * 60)
        let activeElapsed = PacingKernel.activeHoursInRange(from: weekStart, to: timestamp, schedule: schedule)
        let activeTotal = PacingKernel.activeHoursInRange(from: weekStart, to: resetAt, schedule: schedule)
        guard activeTotal > 0 else { return 0 }
        return min(100, (activeElapsed / activeTotal) * 100)
    }

    private static func usageValue(
        expected: Double,
        progress: Double,
        profile: PacingUsageProfile,
        generator: inout SeededGenerator
    ) -> Double {
        let value: Double = switch profile {
        case .onPace:
            expected
        case .frontLoaded:
            expected + (1 - progress) * 18
        case .lateBurst:
            expected - (1 - progress) * 18
        case .bursty:
            expected + Double.random(in: -9...9, using: &generator)
        }
        return max(0, min(99, value))
    }

    private static func completedWeekSegment(
        windowEnd: Date,
        utilization: Double,
        schedule _: PacingScheduleContext
    ) -> [Poll] {
        let timestamps = [
            windowEnd.addingTimeInterval(-3 * 3600),
            windowEnd.addingTimeInterval(-90 * 60),
            windowEnd.addingTimeInterval(-5 * 60),
        ]
        let usages = [max(utilization - 3, 0), max(utilization - 1, 0), utilization]
        let sessionUsages = [18.0, 33.0, 56.0]
        let remaining = [180.0, 90.0, 5.0]

        return zip(zip(timestamps, usages), zip(sessionUsages, remaining)).map { outer, session in
            Poll(
                timestamp: outer.0,
                sessionUsage: session.0,
                sessionRemaining: session.1,
                weeklyUsage: outer.1,
                weeklyRemaining: max(windowEnd.timeIntervalSince(outer.0) / 60, 0),
                weeklyResetAt: windowEnd
            )
        }
    }

    private static func makeDate(
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
}

private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1
        return state
    }
}
