import Foundation

struct UsageWindow: Codable, Sendable {
    let utilization: Double
    let resets_at: String?
}

struct ScopedModel: Codable, Sendable {
    let id: String?
    let display_name: String?
}

struct LimitScope: Codable, Sendable {
    let model: ScopedModel?
}

struct Limit: Codable, Sendable {
    let kind: String?
    let group: String?
    let percent: Double?
    let resets_at: String?
    let scope: LimitScope?
    let is_active: Bool?
}

struct UsageLimits: Codable, Sendable {
    let five_hour: UsageWindow?
    let seven_day: UsageWindow?
    let rate_limit_tier: String?
    let limits: [Limit]?

    var fableWeekly: Limit? {
        limits?.first { $0.scope?.model?.display_name == "Fable" }
    }
}
