import ArgumentParser
import ClacalCore
import Darwin
import Foundation

@main
struct ClacalCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clacal",
        abstract: "Print current Claude Code usage as Markdown."
    )

    mutating func run() async {
        do {
            let snapshot = try await UsageReporter.fetchFresh()
            print(MarkdownUsageRenderer.usage(snapshot), terminator: "")
        } catch {
            FileHandle.standardError.write(Data(MarkdownUsageRenderer.error(error).utf8))
            Darwin.exit(1)
        }
    }
}
