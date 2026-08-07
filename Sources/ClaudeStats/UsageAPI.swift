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
                return "Token rejected. Open Claude Code to refresh your login."
            case .http(let code, let body):
                let trimmed = body.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Usage API returned \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }

    static func fetch() async throws -> UsageResponse {
        let (token, _) = try Keychain.accessToken()

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
