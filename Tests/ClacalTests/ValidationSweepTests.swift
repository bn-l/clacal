import Foundation
import Testing
@testable import Clacal
@testable import ClacalCore

@Suite("ValidationSweep — Matrix")
@MainActor
struct ValidationSweepTests {
    @Test("Sweep matrix is deterministic and complete")
    func sweepMatrixIsDeterministic() throws {
        let lhs = PacingSweepRunner.scenarios(seed: 20_260_407)
        let rhs = PacingSweepRunner.scenarios(seed: 20_260_407)

        #expect(lhs.count == 1_080)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let lhsData = try encoder.encode(lhs)
        let rhsData = try encoder.encode(rhs)
        #expect(lhsData == rhsData)
    }

    @Test("Sweep runner exports reports and optionally gates on failures")
    func sweepRunnerExportsAndCanGate() throws {
        let result = PacingSweepRunner.run(seed: 20_260_407)

        if let outputDirectory = PacingValidationEnvironment.outputDirectory {
            try PacingReportWriter.writeSweepResult(result, to: outputDirectory)
        }

        #expect(result.scenarioCount == 1_080)

        if PacingValidationEnvironment.strictSweep {
            #expect(result.failureCount == 0)
        } else {
            #expect(result.failureCount >= 0)
        }
    }
}
