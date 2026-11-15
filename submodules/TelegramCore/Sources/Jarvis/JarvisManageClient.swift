import Foundation

public enum JarvisModelMode: String, Codable, Sendable {
    case platform
    case hosted = "hosted_byok"
    case local = "local_byok"
}

public struct JarvisModelConfiguration: Decodable, Sendable {
    public let schemaVersion: Int
    public let mode: JarvisModelMode
    public let hostedKeyPresent: Bool
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", mode, hostedKeyPresent = "hosted_key_present"
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

public enum JarvisManageError: Error {
    case invalidConfiguration, authenticationRequired, forbidden, hostedKeyRequired, unavailable, incompatibleResponse
}

public enum JarvisManageRequest {
    private static func make(origin: URL, ticket: String, action: String, body: [String: Any]?) throws -> URLRequest {
        guard var url = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              url.scheme == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", !ticket.isEmpty,
              !ticket.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JarvisManageError.invalidConfiguration
        }
        url.path = "/api/jarvis/manage"
        url.queryItems = [URLQueryItem(name: "action", value: action)]
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
    public static func context(origin: URL, ticket: String, peerId: Int64, query: String = "") throws -> URLRequest {
        guard peerId > 0, query.unicodeScalars.count <= 200 else { throw JarvisManageError.invalidConfiguration }
        return try make(origin: origin, ticket: ticket, action: "local_context", body: ["peer_id": peerId, "query": query])
    }
    public static func deleteHostedKey(origin: URL, ticket: String) throws -> URLRequest {
        return try make(origin: origin, ticket: ticket, action: "delete_hosted_key", body: [:])
    }
    public static func validate(status: Int, data: Data) throws {
        switch status {
        case 401: throw JarvisManageError.authenticationRequired
        case 403: throw JarvisManageError.forbidden
        case 409: throw JarvisManageError.hostedKeyRequired
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
                let deletion = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                    $0.name == "action" && $0.value == "delete_hosted_key"
                }) == true
                guard json["schema_version"] as? Int == 1 || (deletion && json["ok"] as? Bool == true) else {
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
