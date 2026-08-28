import Foundation

/// Reads Codex usage for a ChatGPT-plan login, the same way this app reads Claude:
/// borrow the CLI's own credentials read-only, call the usage endpoint directly,
/// and when the token has gone stale ask the CLI to renew it rather than ever
/// redeeming the (rotating) refresh token ourselves.
enum CodexAPI {
    /// `~/.codex/auth.json`, or wherever `$CODEX_HOME` points.
    private static var authFile: URL {
        let home = ProcessInfo.processInfo.environment["CODEX_HOME"]
            ?? "\(NSHomeDirectory())/.codex"
        return URL(fileURLWithPath: home).appendingPathComponent("auth.json")
    }

    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Whether this machine has a Codex ChatGPT login worth polling at all.
    /// API-key-only configurations are excluded — the usage endpoint serves
    /// subscription quotas, which an API key doesn't have.
    ///
    /// Checked live (memoised on the file's modification date, since it is asked
    /// on every repaint) so a `codex login` or `codex logout` mid-run takes
    /// effect without relaunching the app.
    static var isAvailable: Bool {
        let mtime = (try? FileManager.default
            .attributesOfItem(atPath: authFile.path))?[.modificationDate] as? Date
        availabilityLock.lock()
        defer { availabilityLock.unlock() }
        if let availability, availability.mtime == mtime { return availability.available }
        let available = (try? credentials()) != nil
        availability = (mtime, available)
        return available
    }

    private static let availabilityLock = NSLock()
    nonisolated(unsafe) private static var availability: (mtime: Date?, available: Bool)?

    enum APIError: LocalizedError {
        case notLoggedIn
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case http(Int, String)

        var errorDescription: String? {
            switch self {
            case .notLoggedIn:
                return "No Codex login found. Run `codex login` to sign in."
            case .unauthorized:
                return "Codex's login has expired and couldn't be renewed automatically."
            case .rateLimited:
                return "Rate limited by the Codex usage API — backing off."
            case .http(let code, let body):
                let trimmed = body.prefix(120).trimmingCharacters(in: .whitespacesAndNewlines)
                return "Codex usage API returned \(code)\(trimmed.isEmpty ? "" : ": \(trimmed)")"
            }
        }
    }

    struct Result {
        let limits: [Limit]
        /// Plan and credits, already worded for the dropdown footer.
        let footnote: String?
        let renewedLogin: Bool
    }

    // MARK: Credentials

    private struct Credentials {
        let token: String
        let accountID: String?
        let expiresAt: Date?
    }

    /// How close to expiry we start renewing rather than waiting for a 401.
    private static let renewWindow: TimeInterval = 60

    private static func credentials() throws -> Credentials {
        guard let data = try? Data(contentsOf: authFile),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = (root["tokens"] ?? root["Tokens"]) as? [String: Any],
              let token = (tokens["access_token"] ?? tokens["accessToken"]) as? String,
              !token.isEmpty
        else { throw APIError.notLoggedIn }

        let claims = jwtClaims(of: token)
        let accountID = (tokens["account_id"] ?? tokens["accountId"]) as? String
            ?? claims?["chatgpt_account_id"] as? String
            ?? (claims?["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String

        let expiresAt = (claims?["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        return Credentials(token: token, accountID: accountID, expiresAt: expiresAt)
    }

    private static func jwtClaims(of token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Fetch

    static func fetch() async throws -> Result {
        var credentials = try credentials()
        var renewed = false

        if let expiry = credentials.expiresAt, expiry.timeIntervalSinceNow < renewWindow {
            renewed = await renewLogin()
            if renewed { credentials = (try? Self.credentials()) ?? credentials }
        }

        do {
            let result = try await request(with: credentials, renewedLogin: renewed)
            if renewed { Log.write("renewed codex login, \(result.limits.count) limits") }
            return result
        } catch APIError.unauthorized {
            Log.write("codex 401 — asking the CLI to renew")
            guard await renewLogin(), let fresh = try? Self.credentials() else {
                Log.write("codex renewal did not produce a new token")
                throw APIError.unauthorized
            }
            return try await request(with: fresh, renewedLogin: true)
        }
    }

    /// Ask the CLI to renew, and report whether the stored token actually moved.
    /// The file comparison is the whole verdict: the CLI refreshes `auth.json` as
    /// soon as it loads stale credentials, so the token can be renewed even when
    /// the RPC round trip itself times out.
    private static func renewLogin() async -> Bool {
        let before = try? credentials()
        _ = await CodexCLI.refreshAuth()
        let after = try? credentials()
        return after?.token != before?.token
    }

    private static func request(with credentials: Credentials, renewedLogin: Bool) async throws -> Result {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("Bearer \(credentials.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeStats/1.0 (menu bar)", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0

        guard code == 200 else {
            if code == 401 || code == 403 { throw APIError.unauthorized }
            if code == 429 {
                let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "retry-after")
                Log.write("codex HTTP 429, retry-after: \(header ?? "absent")")
                throw APIError.rateLimited(retryAfter: header.flatMap(TimeInterval.init))
            }
            let body = String(data: data, encoding: .utf8) ?? ""
            Log.write("codex HTTP \(code): \(body.prefix(200).replacingOccurrences(of: "\n", with: " "))")
            throw APIError.http(code, body)
        }

        return try parse(data, renewedLogin: renewedLogin)
    }

    /// Turns a `wham/usage` body into limits and a footnote. Separate from the
    /// request so the mapping can be exercised against captured responses.
    static func parse(_ data: Data, renewedLogin: Bool = false) throws -> Result {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let wham: WhamUsage
        do {
            wham = try decoder.decode(WhamUsage.self, from: data)
        } catch {
            Log.write("codex decode failed: \(error)")
            throw error
        }
        return Result(limits: limits(from: wham), footnote: footnote(for: wham), renewedLogin: renewedLogin)
    }

    // MARK: Wire format

    /// `GET /backend-api/wham/usage` — the same numbers the Codex CLI's `/status`
    /// shows. `primary_window` is the 5-hour session, `secondary_window` the week;
    /// the window length says which is which, not the position.
    private struct WhamUsage: Decodable {
        struct Window: Decodable {
            let usedPercent: Double?
            let resetAt: Double?           // epoch seconds
            let resetAfterSeconds: Double?
            let limitWindowSeconds: Double?
        }
        struct RateLimit: Decodable {
            let primaryWindow: Window?
            let secondaryWindow: Window?
        }
        struct Credits: Decodable {
            let hasCredits: Bool?
            let unlimited: Bool?
            let balance: Balance?

            /// The balance arrives as a number or a numeric string, depending on
            /// which backend served the request.
            struct Balance: Decodable {
                let value: Double?
                init(from decoder: Decoder) throws {
                    let container = try decoder.singleValueContainer()
                    value = (try? container.decode(Double.self))
                        ?? (try? container.decode(String.self)).flatMap(Double.init)
                }
            }
        }
        struct Additional: Decodable {
            let limitName: String?
            let rateLimit: RateLimit?
        }

        let planType: String?
        let rateLimit: RateLimit?
        let credits: Credits?
        let additionalRateLimits: [Additional]?
    }

    private static func limits(from wham: WhamUsage) -> [Limit] {
        var collected = limits(from: wham.rateLimit, scopeName: nil)
        for extra in wham.additionalRateLimits ?? [] {
            collected.append(contentsOf: limits(from: extra.rateLimit, scopeName: extra.limitName))
        }
        return collected
    }

    private static func limits(from rateLimit: WhamUsage.RateLimit?, scopeName: String?) -> [Limit] {
        [(rateLimit?.primaryWindow, true), (rateLimit?.secondaryWindow, false)].compactMap { window, isPrimary in
            guard let window, let percent = window.usedPercent else { return nil }

            // ≤ 6h → the session window, ≤ 8 days → the weekly one; anything
            // longer is a monthly lane, which `Gauge` prettifies from the kind.
            // A window that omits its length falls back to position (primary is
            // the short one) — defaulting the length to 0 instead would classify
            // the weekly window as a second "session" and collide their series.
            let weekly = (scopeName == nil ? "weekly_all" : "weekly_scoped", "weekly")
            let kind: String
            let group: String
            switch window.limitWindowSeconds {
            case .some(..<21_600): (kind, group) = ("session", "session")
            case .some(..<700_000): (kind, group) = weekly
            case .some: (kind, group) = ("monthly", "monthly")
            case nil: (kind, group) = isPrimary ? ("session", "session") : weekly
            }

            let resetsAt = window.resetAt.map(Date.init(timeIntervalSince1970:))
                ?? window.resetAfterSeconds.map { Date().addingTimeInterval($0) }

            let scope = scopeName.map {
                Limit.Scope(model: .init(id: nil, displayName: $0), surface: nil)
            }
            return Limit(
                kind: kind,
                group: group,
                percent: percent,
                severity: nil,
                resetsAt: resetsAt,
                scope: scope,
                isActive: nil
            )
        }
    }

    private static func footnote(for wham: WhamUsage) -> String? {
        var parts: [String] = []
        if let plan = wham.planType, !plan.isEmpty {
            parts.append("\(plan.replacingOccurrences(of: "_", with: " ").capitalized) plan")
        }
        if let credits = wham.credits, credits.hasCredits == true {
            if credits.unlimited == true {
                parts.append("unlimited credits")
            } else if let balance = credits.balance?.value, balance.isFinite {
                // The range guard matters: `Int(_: Double)` traps beyond Int range,
                // and the balance is server-controlled.
                let rounded = balance == balance.rounded() && abs(balance) < 1e15
                    ? String(Int(balance))
                    : String(format: "%.2f", balance)
                parts.append("\(rounded) credits")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
