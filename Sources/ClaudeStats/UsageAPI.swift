import Foundation

// MARK: - Wire format

struct UsageResponse: Decodable {
    let limits: [Limit]
    let extraUsage: ExtraUsage?
}

struct Limit: Decodable {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped" | …
    let group: String?      // "session" | "weekly"
    let percent: Double
    let severity: String?   // "normal" | "warning" | "critical" | …
    let resetsAt: Date?
    let scope: Scope?
    let isActive: Bool?

    struct Scope: Decodable {
        struct Model: Decodable {
            let id: String?
            let displayName: String?
        }
        let model: Model?
        let surface: String?
    }
}

struct ExtraUsage: Decodable {
    let isEnabled: Bool?
    let utilization: Double?
    let usedCredits: Double?
    let monthlyLimit: Double?
    let currency: String?
}

// MARK: - Client

enum UsageAPI {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum APIError: LocalizedError {
        case unauthorized
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Claude Code's login has expired and couldn't be renewed automatically."
            case .http(let code, let body):
                let trimmed = body.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Usage API returned \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }

    /// What a poll produced, plus whether the CLI had to be nudged to get there —
    /// the menu surfaces that so a silently self-healing login is still visible.
    struct Result {
        let usage: UsageResponse
        let renewedLogin: Bool
    }

    /// How close to expiry we start renewing rather than waiting for a 401.
    private static let renewWindow: TimeInterval = 10 * 60

    static func fetch() async throws -> Result {
        var credentials = try Keychain.accessToken()
        var renewed = false

        // Pre-empt the expiry when we can see it coming: cheaper than a failed
        // round trip, and it keeps the numbers from flickering into a warning.
        if let expiry = credentials.expiresAt, expiry.timeIntervalSinceNow < renewWindow {
            renewed = await renewLogin()
            if renewed { credentials = (try? Keychain.accessToken()) ?? credentials }
        }

        do {
            return Result(usage: try await request(token: credentials.token), renewedLogin: renewed)
        } catch APIError.unauthorized {
            // Either the expiry was wrong or the token was revoked — one retry.
            guard await renewLogin(), let fresh = try? Keychain.accessToken() else {
                throw APIError.unauthorized
            }
            return Result(usage: try await request(token: fresh.token), renewedLogin: true)
        }
    }

    /// Ask the CLI to renew, and report whether the stored token actually moved
    /// rather than trusting the command's exit code alone.
    private static func renewLogin() async -> Bool {
        let before = try? Keychain.accessToken()
        guard await ClaudeCLI.refreshAuth() else { return false }
        let after = try? Keychain.accessToken()
        return after?.token != before?.token
    }

    private static func request(token: String) async throws -> UsageResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("ClaudeStats/1.0 (menu bar)", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard code == 200 else {
            if code == 401 || code == 403 { throw APIError.unauthorized }
            throw APIError.http(code, String(data: data, encoding: .utf8) ?? "")
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = ISO8601.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Unrecognised timestamp: \(raw)"
                )
            }
            return date
        }
        return try decoder.decode(UsageResponse.self, from: data)
    }
}

/// The API sends microsecond precision (`…:00.914770+00:00`), which the strict
/// ISO8601 formatter only tolerates some of the time — so try both shapes.
enum ISO8601 {
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ raw: String) -> Date? {
        if let d = fractional.date(from: raw) { return d }
        if let d = plain.date(from: raw) { return d }
        // Clamp over-long fractional parts to milliseconds and retry.
        if let dot = raw.firstIndex(of: ".") {
            let after = raw.index(after: dot)
            if let end = raw[after...].firstIndex(where: { !$0.isNumber }) {
                let digits = raw[after..<end]
                if digits.count > 3 {
                    let clamped = raw[..<after] + digits.prefix(3) + raw[end...]
                    return fractional.date(from: String(clamped))
                }
            }
        }
        return nil
    }
}
