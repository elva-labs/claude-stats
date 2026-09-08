import Foundation

// MARK: - Wire format

struct UsageResponse: Decodable {
    let limits: [Limit]
    let extraUsage: ExtraUsage?
}

struct Limit: Codable {
    let kind: String        // "session" | "weekly_all" | "weekly_scoped" | …
    let group: String?      // "session" | "weekly"
    let percent: Double
    let severity: String?   // "normal" | "warning" | "critical" | …
    let resetsAt: Date?
    let scope: Scope?
    let isActive: Bool?

    struct Scope: Codable {
        struct Model: Codable {
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
        /// The endpoint rejected the stored access token but the refresh token is
        /// still good, so Claude Code will renew it the next time it runs. Carries
        /// the rejected token so the caller can tell when the keychain has moved.
        case loginStale(token: String)
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .unauthorized:
                return "Claude Code's login has expired. Sign in again to continue."
            case .loginStale:
                return "Waiting for Claude Code to renew its login."
            case .rateLimited:
                return "Rate limited by the usage API — backing off."
            case .http(let code, let body):
                let trimmed = body.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Usage API returned \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }

    /// Fetches the current usage with whatever token Claude Code has stored.
    ///
    /// Access tokens last about eight hours and only Claude Code can renew them
    /// (see `ClaudeCLI`). Once the endpoint has rejected a token, asking again with
    /// the same one is pointless and gets the app throttled, so the caller passes
    /// the rejected token back in as `staleToken` and this only goes to the network
    /// once the keychain holds a different one.
    static func fetch(staleToken: String? = nil) async throws -> UsageResponse {
        let credentials: Keychain.Credentials
        do {
            credentials = try Keychain.credentials()
        } catch {
            Log.write("keychain read failed: \(error.localizedDescription)")
            throw error
        }

        if let staleToken, credentials.accessToken == staleToken {
            throw APIError.loginStale(token: staleToken)
        }

        do {
            return try await request(token: credentials.accessToken)
        } catch APIError.unauthorized {
            if let refreshExpiry = credentials.refreshExpiresAt, refreshExpiry <= Date() {
                Log.write("401 and the refresh token expired \(ISO8601DateFormatter().string(from: refreshExpiry)) — sign-in needed")
                throw APIError.unauthorized
            }
            Log.write("401 — waiting for Claude Code to renew its login")
            throw APIError.loginStale(token: credentials.accessToken)
        }
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
            if code == 429 {
                let header = (response as? HTTPURLResponse)?
                    .value(forHTTPHeaderField: "retry-after")
                Log.write("HTTP 429, retry-after: \(header ?? "absent")")
                throw APIError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.write("HTTP \(code): \(body.prefix(200).replacingOccurrences(of: "\n", with: " "))")
            throw APIError.http(code, body)
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
        do {
            return try decoder.decode(UsageResponse.self, from: data)
        } catch {
            Log.write("decode failed: \(error)")
            throw error
        }
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
