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

    @Flag(help: "Include usage statistics.")
    var stats = false

    @Flag(help: "Include weekly usage history.")
    var history = false

    mutating func run() async {
        do {
            let snapshot = try await UsageReporter.fetchFresh()
            print(
                MarkdownUsageRenderer.usage(
                    snapshot,
                    includeStats: stats,
                    includeHistory: history
                ),
                terminator: ""
            )
        } catch {
            FileHandle.standardError.write(Data(MarkdownUsageRenderer.error(error).utf8))
            Darwin.exit(1)
        }
    }
}
