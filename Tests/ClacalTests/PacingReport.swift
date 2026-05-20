import Foundation
@testable import Clacal
@testable import ClacalCore

enum PacingValidationEnvironment {
    static var outputDirectory: URL? {
        guard let raw = ProcessInfo.processInfo.environment["CLACAL_VALIDATION_OUTPUT_DIR"],
              !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: raw, isDirectory: true)
    }

    static var strictSweep: Bool {
        ProcessInfo.processInfo.environment["CLACAL_VALIDATION_STRICT"] == "1"
    }
}

enum PacingReportWriter {
    static func writeReplayResults(_ results: [PacingReplayResult], to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let summaryURL = directory.appending(path: "summary.md")
        try markdownSummary(for: results).write(to: summaryURL, atomically: true, encoding: .utf8)

        for result in results {
            let slug = sanitize(result.fixture.name)
            let jsonURL = directory.appending(path: "\(slug).json")
            let data = try encoder.encode(result)
            try data.write(to: jsonURL, options: .atomic)
        }
    }

    static func writeSweepResult(_ result: PacingSweepResult, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let jsonURL = directory.appending(path: "sweep.json")
        try encoder.encode(result).write(to: jsonURL, options: .atomic)

        let summaryURL = directory.appending(path: "sweep.md")
        try sweepSummary(for: result).write(to: summaryURL, atomically: true, encoding: .utf8)

        let failuresDirectory = directory.appending(path: "failures", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: failuresDirectory, withIntermediateDirectories: true)
        try writeReplayResults(result.failed, to: failuresDirectory)
    }

    private static func markdownSummary(for results: [PacingReplayResult]) -> String {
        let passed = results.filter(\.matchesExpectation).count
        let failed = results.count - passed
        let body = results.map { result in
            let status = result.matchesExpectation ? "PASS" : "FAIL"
            let failureKinds = result.failureKinds.map(\.rawValue).joined(separator: ", ")
            return "- \(status) `\(result.fixture.name)`\(failureKinds.isEmpty ? "" : " — \(failureKinds)")"
        }
        return ([
            "# Validation Summary",
            "",
            "- Total scenarios: \(results.count)",
            "- Passing scenarios: \(passed)",
            "- Failing scenarios: \(failed)",
            "",
        ] + body).joined(separator: "\n")
    }

    private static func sweepSummary(for result: PacingSweepResult) -> String {
        let lines = result.failed.prefix(25).map { failed in
            "- `\(failed.fixture.name)` — \(failed.failureKinds.map(\.rawValue).joined(separator: ", "))"
        }
        return ([
            "# Sweep Summary",
            "",
            "- Seed: \(result.seed)",
            "- Scenario count: \(result.scenarioCount)",
            "- Failure count: \(result.failureCount)",
            "",
            "## First Failures",
        ] + lines).joined(separator: "\n")
    }

    private static func sanitize(_ raw: String) -> String {
        raw.replacingOccurrences(of: #"[^A-Za-z0-9._-]+"#, with: "_", options: .regularExpression)
    }
}
