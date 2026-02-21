import Foundation
import OSLog

private let logger = Logger(subsystem: "com.bml.clacal", category: "DataStore")

struct Poll: Codable, Sendable {
    let timestamp: Date
    let sessionUsage: Double
    let sessionRemaining: Double
    let weeklyUsage: Double
    let weeklyRemaining: Double
}

struct SessionStart: Codable, Sendable {
    let timestamp: Date
    let weeklyUsage: Double
    let weeklyRemaining: Double
}

struct DailySnapshot: Codable, Sendable {
    let date: Date
    let weeklyUsagePct: Double
    let weeklyMinsLeft: Double
}

struct DailyActivity: Codable, Sendable {
    let date: Date
    var activeMinutes: Double
    var idleMinutes: Double
}

struct StoreData: Codable, Sendable {
    var polls: [Poll] = []
    var sessions: [SessionStart] = []
    var dailySnapshot: DailySnapshot?
    var dailyActivities: [DailyActivity] = []

    init(polls: [Poll] = [], sessions: [SessionStart] = [], dailySnapshot: DailySnapshot? = nil, dailyActivities: [DailyActivity] = []) {
        self.polls = polls
        self.sessions = sessions
        self.dailySnapshot = dailySnapshot
        self.dailyActivities = dailyActivities
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        polls = try container.decodeIfPresent([Poll].self, forKey: .polls) ?? []
        sessions = try container.decodeIfPresent([SessionStart].self, forKey: .sessions) ?? []
        dailySnapshot = try container.decodeIfPresent(DailySnapshot.self, forKey: .dailySnapshot)
        dailyActivities = try container.decodeIfPresent([DailyActivity].self, forKey: .dailyActivities) ?? []
    }
}

enum DataStore {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: ".config/clacal/usage_data.json")

    static func load(from url: URL = defaultURL) -> StoreData {
        guard let raw = try? Data(contentsOf: url) else {
            logger.info("No data file at \(url.path(), privacy: .public) — starting fresh")
            return StoreData()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        guard let store = try? decoder.decode(StoreData.self, from: raw) else {
            logger.error("Failed to decode data file at \(url.path(), privacy: .public) — starting fresh")
            return StoreData()
        }
        logger.info("Loaded data: polls=\(store.polls.count, privacy: .public) sessions=\(store.sessions.count, privacy: .public)")
        return store
    }

    static func save(_ data: StoreData, to url: URL = defaultURL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let raw = try? encoder.encode(data) else {
            logger.error("Failed to encode data for save")
            return
        }
        do {
            try raw.write(to: url, options: .atomic)
            logger.debug("Data saved: polls=\(data.polls.count, privacy: .public) sessions=\(data.sessions.count, privacy: .public)")
        } catch {
            logger.error("Failed to write data: \(error.localizedDescription, privacy: .public)")
        }
    }
}
