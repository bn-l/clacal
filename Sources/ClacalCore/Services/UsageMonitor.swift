import Foundation
import Observation
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "Monitor")

public struct AppError: Identifiable, Sendable {
    public let id = UUID()
    public let message: String
    public let timestamp: Date

    public init(message: String, timestamp: Date = Date()) {
        self.message = message
        self.timestamp = timestamp
    }
}

@Observable
@MainActor
public final class UsageMonitor {
    public var metrics: UsageMetrics? {
        didSet {
            logger.trace("metrics updated: calibrator=\(self.metrics?.calibrator ?? -99, privacy: .public)")
        }
    }
    public var errors: [AppError] = []
    public var hasError: Bool { !errors.isEmpty }
    public var isLoading = false
    public var lastUpdated: Date?
    var config = AppConfig.load()
    public var displayMode: MenuBarDisplayMode {
        get { config.menuBarDisplayMode }
        set {
            config.menuBarDisplayMode = newValue
            config.save()
        }
    }
    private var napActivity: (any NSObjectProtocol)?

    // internal(set) for test injection
    var optimiser: UsageOptimiser?

    public init() {}

    public func computeStats() -> UsageStats? {
        optimiser?.computeStats()
    }

    public func toggleDisplayMode() {
        displayMode = displayMode == .calibrator ? .dualBar : .calibrator
    }

    public func manualPoll() async {
        logger.info("Manual poll triggered")
        await poll()
    }

    public func startPolling() async {
        logger.info("startPolling: pollInterval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        napActivity = ProcessInfo.processInfo.beginActivity(options: .background, reason: "Periodic API polling")

        ensureOptimiser()

        logger.info("Starting initial poll")
        await poll()

        logger.info("Entering polling loop: interval=\(self.config.pollIntervalSeconds, privacy: .public)s")
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.pollIntervalSeconds))
            logger.debug("Poll timer fired")
            await poll()
        }
        logger.info("Polling loop exited: cancelled=\(Task.isCancelled, privacy: .public)")
    }

    func processResponse(
        sessionUsagePct: Double,
        weeklyUsagePct: Double,
        sessionMinsLeft: Double,
        weeklyMinsLeft: Double,
        weeklyResetAt: Date? = nil,
        isSessionActive: Bool = true
    ) {
        logger.debug("Raw values: sessionUsagePct=\(sessionUsagePct, privacy: .public) weeklyUsagePct=\(weeklyUsagePct, privacy: .public) sessionMinsLeft=\(sessionMinsLeft, privacy: .public) weeklyMinsLeft=\(weeklyMinsLeft, privacy: .public)")

        ensureOptimiser()

        let snapshot = UsageSnapshotBuilder.make(
            sessionUsagePct: sessionUsagePct,
            weeklyUsagePct: weeklyUsagePct,
            sessionMinsLeft: sessionMinsLeft,
            weeklyMinsLeft: weeklyMinsLeft,
            weeklyResetAt: weeklyResetAt,
            isSessionActive: isSessionActive,
            optimiser: optimiser!,
            now: Date()
        )

        metrics = snapshot.metrics
        errors.removeAll()
        lastUpdated = snapshot.generatedAt

        logger.info("Poll complete: calibrator=\(snapshot.metrics.calibrator, privacy: .public) target=\(snapshot.metrics.sessionTarget, privacy: .public)")
    }

    private func ensureOptimiser() {
        guard optimiser == nil else { return }
        optimiser = UsageOptimiser(
            data: DataStore.load(),
            activeHoursPerDay: config.activeHoursPerDay,
            persistURL: DataStore.defaultURL
        )
    }

    private func appendError(_ message: String) {
        logger.debug("Error recorded: \(message, privacy: .public)")
        errors.append(AppError(message: message))
        if errors.count > 10 { errors.removeFirst(errors.count - 10) }
    }

    private func poll() async {
        logger.debug("poll() start")
        isLoading = true
        defer {
            isLoading = false
            logger.debug("poll() end")
        }

        do {
            guard let token = await CredentialProvider.readTokenAsync() else {
                appendError("No OAuth token in Keychain. Run: claude login")
                logger.warning("No credentials available, skipping poll")
                return
            }

            let response = try await UsageAPIClient.fetch(token: token)
            if response.five_hour == nil {
                logger.warning("API response missing five_hour window — defaulting to 0")
            }
            if response.seven_day == nil {
                logger.warning("API response missing seven_day window — defaulting to 0")
            }
            ensureOptimiser()
            let snapshot = UsageSnapshotBuilder.make(
                response: response,
                optimiser: optimiser!,
                now: Date()
            )
            metrics = snapshot.metrics
            errors.removeAll()
            lastUpdated = snapshot.generatedAt
        } catch {
            appendError(error.localizedDescription)
            logger.error("Poll failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func minutesUntil(_ isoString: String?) -> Double {
        let mins = UsageTimeParser.minutesUntil(isoString)
        if let isoString {
            logger.trace("minutesUntil: input=\(isoString, privacy: .public) minutes=\(mins, privacy: .public)")
        }
        return mins
    }
}

// MARK: - Config

public enum MenuBarDisplayMode: String, Codable, Sendable {
    case calibrator
    case dualBar
}

struct AppConfig: Codable, Sendable {
    var activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10]
    var pollIntervalSeconds: Int = 300
    var menuBarDisplayMode: MenuBarDisplayMode = .calibrator

    init(
        activeHoursPerDay: [Double] = [10, 10, 10, 10, 10, 10, 10],
        pollIntervalSeconds: Int = 300,
        menuBarDisplayMode: MenuBarDisplayMode = .calibrator
    ) {
        self.activeHoursPerDay = activeHoursPerDay
        self.pollIntervalSeconds = pollIntervalSeconds
        self.menuBarDisplayMode = menuBarDisplayMode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeHoursPerDay = try container.decodeIfPresent([Double].self, forKey: .activeHoursPerDay) ?? [10, 10, 10, 10, 10, 10, 10]
        pollIntervalSeconds = try container.decodeIfPresent(Int.self, forKey: .pollIntervalSeconds) ?? 300
        menuBarDisplayMode = try container.decodeIfPresent(MenuBarDisplayMode.self, forKey: .menuBarDisplayMode) ?? .calibrator
    }

    private static let configURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/clacal/config.json")

    static func load() -> AppConfig {
        load(from: configURL)
    }

    static func load(from url: URL) -> AppConfig {
        let path = url.path()
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            logger.info("Config file not readable at \(path, privacy: .public): \(error.localizedDescription, privacy: .public) — using defaults")
            return AppConfig()
        }
        guard let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            logger.error("Config file at \(path, privacy: .public) exists but failed to decode (\(data.count, privacy: .public) bytes) — using defaults")
            return AppConfig()
        }
        logger.info("Config loaded: path=\(path, privacy: .public) activeHoursPerDay=\(config.activeHoursPerDay, privacy: .public) pollIntervalSeconds=\(config.pollIntervalSeconds, privacy: .public) displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        return config
    }

    func save() {
        Self.save(self, to: Self.configURL)
    }

    static func save(_ config: AppConfig, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        guard let data = try? encoder.encode(config) else {
            logger.error("Failed to encode config for save")
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            logger.info("Config saved: displayMode=\(config.menuBarDisplayMode.rawValue, privacy: .public)")
        } catch {
            logger.error("Failed to write config: \(error.localizedDescription, privacy: .public)")
        }
    }
}
