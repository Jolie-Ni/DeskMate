import Foundation

/// Talks to the team hub. Lives in Core rather than Analyzer because sharing is
/// not analysis — it has no dependency on models or the API key.
public struct HubClient {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL = HubClient.configuredBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// Overridable so a local server can be pointed at during development.
    public static var configuredBaseURL: URL {
        if let s = ProcessInfo.processInfo.environment["DESKMATE_HUB_URL"],
           let u = URL(string: s) { return u }
        return URL(string: Config.hubURL)!
    }

    public enum HubError: LocalizedError {
        case http(Int, String)
        case transport(String)

        public var errorDescription: String? {
            switch self {
            case .http(_, let message): return message
            case .transport(let message): return message
            }
        }
    }

    public struct Enrollment: Decodable, Sendable {
        public let installToken: String
        public let orgName: String
        public let authorEmail: String
        public let authorName: String

        enum CodingKeys: String, CodingKey {
            case installToken = "install_token"
            case orgName = "org_name"
            case authorEmail = "author_email"
            case authorName = "author_name"
        }
    }

    public func enroll(code: String, email: String, name: String,
                       deviceName: String) async throws -> Enrollment {
        let body: [String: String] = [
            "code": code, "email": email, "name": name, "device_name": deviceName,
        ]
        return try await send("/v1/enroll", method: "POST", body: body, token: nil,
                              as: Enrollment.self)
    }

    public func share(_ payload: SharePayload, token: String) async throws {
        _ = try await sendRaw("/v1/workflows", method: "POST",
                              rawBody: Data(payload.json().utf8), token: token,
                              extraHeaders: ["Idempotency-Key": payload.idempotencyKey])
    }

    public func retract(key: String, token: String) async throws {
        _ = try await sendRaw("/v1/workflows/\(key)", method: "DELETE",
                              rawBody: nil, token: token)
    }

    // MARK: - Transport

    private func send<T: Decodable>(_ path: String, method: String,
                                    body: [String: String]?, token: String?,
                                    as type: T.Type) async throws -> T {
        let data = try await sendRaw(
            path, method: method,
            rawBody: body.flatMap { try? JSONSerialization.data(withJSONObject: $0) },
            token: token)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw HubError.transport("The server replied in a form this app didn't expect.") }
    }

    @discardableResult
    private func sendRaw(_ path: String, method: String, rawBody: Data?, token: String?,
                         extraHeaders: [String: String] = [:]) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = rawBody
        request.timeoutInterval = 20
        if rawBody != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (k, v) in extraHeaders { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw HubError.transport(error.localizedDescription) }

        guard let http = response as? HTTPURLResponse else {
            throw HubError.transport("No response from the team hub.")
        }
        guard (200..<300).contains(http.statusCode) else {
            // FastAPI puts the human-readable reason in `detail`.
            let detail = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { $0?["detail"] as? String }
            throw HubError.http(http.statusCode, detail ?? "The team hub refused that request.")
        }
        return data
    }
}
