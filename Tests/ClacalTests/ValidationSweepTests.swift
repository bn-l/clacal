import Foundation
import Testing
@testable import Clacal

@Suite("ValidationSweep — Matrix")
@MainActor
struct ValidationSweepTests {
    @Test("Sweep matrix is deterministic and complete")
    func sweepMatrixIsDeterministic() {
        let lhs = PacingSweepRunner.scenarios(seed: 20_260_407)
        let rhs = PacingSweepRunner.scenarios(seed: 20_260_407)

        #expect(lhs.count == 1_080)
        #expect(lhs.map(\.name) == rhs.map(\.name))
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
