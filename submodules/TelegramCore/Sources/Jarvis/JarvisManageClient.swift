import Foundation

// The stable server-side identity of the built-in @jarvis account. The
// profile-page entry and the /setkey handoff both gate on it, so it lives in
// one place instead of being scattered as a literal.
public let jarvisBotUserId: Int64 = 1250000025

// /setkey is the legacy chat command for a hosted key. On mobile it must open
// the native settings page instead of sending the command: a key typed after
// it would otherwise remain in the chat history. The match is deliberately
// exact so ordinary text containing "/setkey" is never swallowed.
public enum JarvisCommandText {
    /// Returns the question after /ask (possibly empty when the user typed the
    /// command alone), or nil when the text is not that command.
    public static func askQuestion(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("/ask") else { return nil }
        let rest = trimmed.dropFirst("/ask".count)
        if let first = rest.first, first != " " && first != "\n" && first != "\t" && first != "@" {
            return nil
        }
        var question = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if question.hasPrefix("@") {
            if let space = question.firstIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
                question = String(question[question.index(after: space)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                question = ""
            }
        }
        if question.count > 1000 {
            question = String(question.prefix(1000))
        }
        return question
    }

    public static func isSetKeyCommand(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("/setkey") else { return false }
        let rest = trimmed.dropFirst("/setkey".count)
        guard let first = rest.first else { return true }
        guard first == " " || first == "\n" || first == "\t" || first == "@" else { return false }
        // Custom endpoints still use the chat command: the native form only
        // offers known providers and must not silently remove that capability.
        var parts = rest.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        if let head = parts.first, head.hasPrefix("@") {
            parts.removeFirst()
        }
        if parts.first?.lowercased() == "custom" {
            return false
        }
        return true
    }
}

public enum JarvisModelMode: String, Codable, Sendable {
    case platform
    case hosted = "hosted_byok"
    case local = "local_byok"
}

public struct JarvisModelConfiguration: Decodable, Sendable, Equatable {
    public let schemaVersion: Int
    public let mode: JarvisModelMode
    public let hostedKeyPresent: Bool
    public let localKeyScope: String?
    public let automaticFallback: Bool?
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", mode, hostedKeyPresent = "hosted_key_present"
        case localKeyScope = "local_key_scope", automaticFallback = "automatic_fallback"
    }
}

public struct JarvisModelModeCapability: Decodable, Sendable, Equatable {
    public let mode: String
    public let available: Bool
    public let credentialStorage: String
    public let inferenceLocation: String
    public let serverVoice: Bool
    public let requiresOnlineDevice: Bool
    enum CodingKeys: String, CodingKey {
        case mode, available
        case credentialStorage = "credential_storage", inferenceLocation = "inference_location"
        case serverVoice = "server_voice", requiresOnlineDevice = "requires_online_device"
    }
}

public struct JarvisModelCapabilities: Decodable, Sendable, Equatable {
    public let schemaVersion: Int
    public let modes: [JarvisModelModeCapability]
    public let automaticFallback: Bool
    public let localContextSchemaVersion: Int
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", modes, automaticFallback = "automatic_fallback"
        case localContextSchemaVersion = "local_context_schema_version"
    }
}

public struct JarvisAuthorizedChat: Decodable, Sendable, Equatable {
    public let peerType: String
    public let peerId: Int64
    public let title: String?
    public let left: Bool?
    public let grantedAt: String?
    enum CodingKeys: String, CodingKey {
        case peerType = "peer_type", peerId = "peer_id", title, left, grantedAt = "granted_at"
    }
}

public struct JarvisAvailableChat: Decodable, Sendable, Equatable {
    public let peerType: String
    public let peerId: Int64
    public let title: String?
    enum CodingKeys: String, CodingKey { case peerType = "peer_type", peerId = "peer_id", title }
}

public struct JarvisOverview: Decodable, Sendable, Equatable {
    public let schemaVersion: Int
    public let premium: Bool
    public let chatTurns: Int?
    public let chatLimit: Int?
    public let summaries: Int?
    public let summaryLimit: Int?
    public let chats: [JarvisAuthorizedChat]
    public let available: [JarvisAvailableChat]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", premium, chats, available
        case chatTurns = "chat_turns", chatLimit = "chat_limit", summaries, summaryLimit = "summary_limit"
    }
}

public struct JarvisEvidence: Decodable, Sendable {
    public let sourceId: String
    public let peerType: String
    public let peerId: Int64
    public let messageId: Int
    public let text: String
    public let truncated: Bool
    enum CodingKeys: String, CodingKey {
        case sourceId = "source_id", peerType = "peer_type", peerId = "peer_id", messageId = "message_id", text, truncated
    }
}

public struct JarvisAuthorizedContext: Decodable, Sendable {
    public let schemaVersion: Int
    public let scope: String
    public let sources: [JarvisEvidence]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", scope, sources }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.scope = try container.decode(String.self, forKey: .scope)
        self.sources = try container.decode([JarvisEvidence].self, forKey: .sources)
        guard schemaVersion == 1, sources.count <= 24, sources.allSatisfy({
            $0.peerType == "channel" && $0.peerId > 0 && $0.messageId > 0 && $0.sourceId == "channel:\($0.peerId):\($0.messageId)"
        }) else { throw JarvisManageError.incompatibleResponse }
    }

    public var prompt: String {
        return sources.map { "[\($0.sourceId)]\($0.truncated ? " (excerpt)" : "") \($0.text)" }.joined(separator: "\n")
    }

    // Only service-issued IDs can become clickable links; model-generated IDs are not authority.
    public func evidence(sourceId: String) -> JarvisEvidence? {
        return sources.first(where: { $0.sourceId == sourceId })
    }
}

public enum JarvisManageError: Error, Equatable {
    case invalidConfiguration, authenticationRequired, forbidden, hostedKeyRequired, operationFailed, unavailable, incompatibleResponse
}

public enum JarvisManageRequest {
    // The caller extracts jarvis_manage_origin from the current account's
    // authenticated appConfig; an arbitrary URL supplied by a message or a
    // deep link must never be accepted.
    public static func trustedOrigin(_ raw: String) -> URL? {
        guard let components = URLComponents(string: raw),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            return nil
        }
        return components.url
    }

    private static func make(origin: URL, ticket: String, action: String, queryItems: [URLQueryItem] = [], body: [String: Any]?) throws -> URLRequest {
        guard let trusted = trustedOrigin(origin.absoluteString),
              var url = URLComponents(url: trusted, resolvingAgainstBaseURL: false),
              !ticket.isEmpty,
              !ticket.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JarvisManageError.invalidConfiguration
        }
        url.path = "/api/jarvis/manage"
        url.queryItems = [URLQueryItem(name: "action", value: action)] + queryItems
        guard let target = url.url else { throw JarvisManageError.invalidConfiguration }
        var request = URLRequest(url: target)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue("Bearer \(ticket)", forHTTPHeaderField: "Authorization")
        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    public static func configuration(origin: URL, ticket: String) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "model_config", body: nil)
    }
    public static func select(origin: URL, ticket: String, mode: JarvisModelMode) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "model_config", body: ["mode": mode.rawValue])
    }
    public static func capabilities(origin: URL, ticket: String) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "model_capabilities", body: nil)
    }
    public static func overview(origin: URL, ticket: String) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "overview", body: nil)
    }
    public static func context(origin: URL, ticket: String, peerId: Int64, query: String = "") throws -> URLRequest {
        guard peerId > 0, query.unicodeScalars.count <= 200 else { throw JarvisManageError.invalidConfiguration }
        return try make(origin: origin, ticket: ticket, action: "local_context", body: ["peer_id": peerId, "query": query])
    }
    public static func hostedKey(origin: URL, ticket: String, provider: String, model: String, key: String) throws -> URLRequest {
        let provider = provider.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.isEmpty, provider.utf8.count <= 64,
              !model.isEmpty, model.utf8.count <= 200,
              !key.isEmpty, key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JarvisManageError.invalidConfiguration
        }
        return try make(origin: origin, ticket: ticket, action: "hosted_key",
                        body: ["provider": provider, "model": model, "key": key])
    }
    public static func grant(origin: URL, ticket: String, peerId: Int64) throws -> URLRequest {
        guard peerId > 0 else { throw JarvisManageError.invalidConfiguration }
        return try make(origin: origin, ticket: ticket, action: "grant",
                        queryItems: [URLQueryItem(name: "peer_type", value: "channel"),
                                     URLQueryItem(name: "peer_id", value: String(peerId))],
                        body: [:])
    }
    public static func revoke(origin: URL, ticket: String, peerId: Int64) throws -> URLRequest {
        guard peerId > 0 else { throw JarvisManageError.invalidConfiguration }
        return try make(origin: origin, ticket: ticket, action: "revoke",
                        queryItems: [URLQueryItem(name: "peer_type", value: "channel"),
                                     URLQueryItem(name: "peer_id", value: String(peerId))],
                        body: [:])
    }
    public static func deleteHostedKey(origin: URL, ticket: String) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "delete_hosted_key", body: [:])
    }
    public static func validate(status: Int, data: Data) throws {
        switch status {
        case 401: throw JarvisManageError.authenticationRequired
        case 403: throw JarvisManageError.forbidden
        case 409: throw JarvisManageError.hostedKeyRequired
        case 422: throw JarvisManageError.operationFailed
        case 200..<300: break
        default: throw JarvisManageError.unavailable
        }
        guard data.count <= 1_048_576 else { throw JarvisManageError.incompatibleResponse }
    }
}

// Uses a fresh short-lived ticket per operation. Callers must bind the origin
// and ticket provider to one current account and discard results on logout.
public final class JarvisManageClient {
    private let session: URLSession
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: JarvisNoRedirectDelegate(), delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }

    @discardableResult
    public func perform<T: Decodable & Sendable>(_ request: URLRequest, as type: T.Type,
                                      completion: @escaping (Result<T, JarvisManageError>) -> Void) -> URLSessionDataTask {
        let task = session.dataTask(with: request) { data, response, error in
            guard error == nil, let response = response as? HTTPURLResponse, let data = data else {
                completion(.failure(.unavailable)); return
            }
            do {
                try JarvisManageRequest.validate(status: response.statusCode, data: data)
                guard let url = request.url,
                      let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw JarvisManageError.incompatibleResponse
                }
                let action = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                    $0.name == "action"
                })?.value
                let acknowledgementActions: Set<String> = ["delete_hosted_key", "hosted_key", "grant", "revoke"]
                let isAcknowledgement = action.map(acknowledgementActions.contains) == true
                guard json["schema_version"] as? Int == 1 || (isAcknowledgement && json["ok"] as? Bool == true) else {
                    throw JarvisManageError.incompatibleResponse
                }
                let result = try JSONDecoder().decode(type, from: data)
                completion(.success(result))
            } catch let error as JarvisManageError { completion(.failure(error)) }
            catch { completion(.failure(.incompatibleResponse)) }
        }
        task.resume()
        return task
    }
}

public struct JarvisManageAcknowledgement: Decodable, Sendable { public let ok: Bool }
