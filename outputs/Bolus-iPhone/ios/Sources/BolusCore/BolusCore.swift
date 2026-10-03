import Foundation

public enum ServerAddress {
    public static func parse(_ text: String) -> URL? {
        guard var parts = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.scheme == "https" || (parts.scheme == "http" && localHost(host)) else { return nil }
        parts.host = host; parts.path = ""
        return parts.url
    }
    public static func localHost(_ host: String) -> Bool {
        if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }) else { return false }
        let bytes = parts.compactMap { Int($0) }
        guard bytes.count == 4, bytes.allSatisfy({ (0...255).contains($0) }) else { return false }
        return bytes[0] == 10 || (bytes[0] == 192 && bytes[1] == 168) || (bytes[0] == 172 && (16...31).contains(bytes[1]))
    }
    public static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func port(_ u: URL) -> Int { u.port ?? (u.scheme == "https" ? 443 : 80) }
        return a.scheme == b.scheme && a.host?.lowercased() == b.host?.lowercased() && port(a) == port(b)
    }
}

public struct HealthWorkout: Codable, Sendable {
    public let id: String
    public let name: String
    public let source_name: String
    public let started_at: String
    public let ended_at: String
    public let duration_minutes: Double
    public let active_energy: Double?
    public let distance_km: Double?
    public init(id: String, name: String, source: String, start: Date, end: Date, minutes: Double, energy: Double?, distance: Double?) {
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        self.id = id; self.name = name; self.source_name = String(source.prefix(100))
        self.started_at = iso.string(from: start); self.ended_at = iso.string(from: end)
        self.duration_minutes = minutes; self.active_energy = energy; self.distance_km = distance
    }
}
public struct HealthDay: Codable, Sendable {
    public var date: String
    public var steps: Int?
    public var active_energy: Double?
    public var exercise_minutes: Double?
    public var distance_km: Double?
    public init(date: String) { self.date = date }
    public var hasData: Bool { steps != nil || active_energy != nil || exercise_minutes != nil || distance_km != nil }
}
public struct HealthPayload: Codable, Sendable {
    public var expected_user_id: String
    public var timezone: String
    public var workouts: [HealthWorkout]
    public var days: [HealthDay]
    public init(userID: String, timezone: String, workouts: [HealthWorkout], days: [HealthDay]) {
        self.expected_user_id = userID; self.timezone = timezone; self.workouts = workouts; self.days = days
    }
}
