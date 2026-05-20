import Foundation
import Testing
@testable import Clacal
@testable import ClacalCore

@Suite(
    "CLI packaging",
    .enabled(
        if: Bundle.main.bundleURL.pathExtension == "app",
        "Requires Xcode app-hosted tests because SwiftPM tests do not build Clacal.app"
    )
)
struct CLIPackagingTests {
    @Test("App and bundled CLI executables are distinct")
    func appAndCLIExecutablesAreDistinct() throws {
        let appBundle = Bundle.main

        let infoExecutable = try #require(appBundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String)
        let macOSURL = appBundle.bundleURL.appending(path: "Contents/MacOS", directoryHint: .isDirectory)
        let appExecutableURL = macOSURL.appending(path: infoExecutable)
        let cliExecutableURL = macOSURL.appending(path: "clacal-cli")

        #expect(infoExecutable == "Clacal")
        #expect(FileManager.default.fileExists(atPath: appExecutableURL.path()))
        #expect(FileManager.default.fileExists(atPath: cliExecutableURL.path()))
        #expect(appExecutableURL.path().lowercased() != cliExecutableURL.path().lowercased())
    }

    @Test("Bundled CLI help writes stdout and exits successfully")
    func bundledCLIHelp() throws {
        let appBundle = Bundle.main

        let cliURL = appBundle.bundleURL
            .appending(path: "Contents/MacOS", directoryHint: .isDirectory)
            .appending(path: "clacal-cli")
        let result = try run(cliURL, arguments: ["--help"])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("USAGE: clacal"))
        #expect(result.stderr.isEmpty)
    }

    private func run(_ executableURL: URL, arguments: [String]) throws -> CommandResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            stderr: String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}

private struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}
