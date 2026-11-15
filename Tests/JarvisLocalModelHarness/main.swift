import Foundation

func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    if !condition() { fatalError(label) }
}

func expectFailure(_ label: String, _ block: () throws -> Void) {
    do { try block(); fatalError(label) } catch is JarvisLocalModelError {} catch { fatalError("Unexpected error type") }
}

let credential = try JarvisLocalCredential(provider: .openai, model: "test-model", key: "synthetic-test-key")
check(!String(reflecting: credential).contains("synthetic-test-key"), "Credential leaked into debug description")
let request = try JarvisLocalModelClient.request(credential: credential, context: "[channel:7:2] A proposal", question: "What was decided?")
check(request.url?.host == "api.openai.com", "Key must only go to selected provider")
check(request.httpMethod == "POST", "Provider requests must use POST")
check(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-key", "Missing authorization")
let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
check(body["model"] as? String == "test-model", "Wrong model")
check(body["key"] == nil, "Credential leaked into body")
let messages = body["messages"] as! [[String: String]]
check(messages[1]["content"]!.contains("channel:7:2"), "Lost evidence ID")
let other = try JarvisLocalCredential(provider: .deepseek, model: "deepseek-chat", key: "another-synthetic-key")
let otherRequest = try JarvisLocalModelClient.request(credential: other, context: "", question: "Hello")
check(otherRequest.url?.host == "api.deepseek.com", "Wrong provider")
check(otherRequest.value(forHTTPHeaderField: "Authorization") == "Bearer another-synthetic-key", "Cross-request key reuse")
expectFailure("Empty keys accepted") { _ = try JarvisLocalCredential(provider: .openai, model: "test", key: " ") }
expectFailure("Header injection accepted") { _ = try JarvisLocalCredential(provider: .openai, model: "test", key: "a\r\nb") }
expectFailure("Invalid account accepted") { _ = try JarvisLocalKeyStore(userId: 0) }
expectFailure("Oversized context accepted") { _ = try JarvisLocalModelClient.request(credential: credential, context: String(repeating: "x", count: 100001), question: "Hello") }
let validResponse = Data(#"{"choices":[{"message":{"content":"Proposal only [channel:7:2]"}}]}"#.utf8)
let answer = try JarvisLocalModelClient.response(status: 200, data: validResponse)
check(answer.contains("channel:7:2"), "Lost answer evidence")
for status in [301, 401, 403, 429, 500] {
    expectFailure("Provider error accepted") { _ = try JarvisLocalModelClient.response(status: status, data: Data("private-provider-error".utf8)) }
}
expectFailure("Invalid JSON accepted") { _ = try JarvisLocalModelClient.response(status: 200, data: Data("invalid".utf8)) }
expectFailure("Tool calls accepted") { _ = try JarvisLocalModelClient.response(status: 200, data: Data(#"{"choices":[{"message":{"content":"done","tool_calls":[]}}]}"#.utf8)) }
print("Jarvis local model iOS core checks passed")

let vectorKey = Data((0..<256).map { UInt8($0) })
if #available(macOS 10.15, *) {
    check(JarvisSessionTicket.make(authKey: vectorKey, authKeyId: UInt64.max, userId: 7, expires: 2000000000) == "djE6MTg0NDY3NDQwNzM3MDk1NTE2MTU6NzoyMDAwMDAwMDAw.hhK9XjIq9xZ_sCs1DwOsYRSgCMi9jo4n6t4R2WjPKps", "Ticket does not match server contract")
    check(JarvisSessionTicket.make(authKey: Data(), authKeyId: 1, userId: 7, expires: 2000000000) == nil, "Invalid session key accepted")
}
let manage = try JarvisManageRequest.context(origin: URL(string: "https://service.example")!, ticket: "synthetic-session-ticket", peerId: 7)
check(manage.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-session-ticket", "Missing session header")
check(!manage.url!.absoluteString.contains("synthetic-session-ticket"), "Ticket leaked into URL")
let modeRequest = try JarvisManageRequest.select(origin: URL(string: "https://service.example")!, ticket: "session", mode: .local)
check(String(data: modeRequest.httpBody!, encoding: .utf8)!.contains("local_byok"), "Incorrect mode contract")
do {
    _ = try JarvisManageRequest.configuration(origin: URL(string: "http://service.example")!, ticket: "session")
    fatalError("Insecure origin accepted")
} catch is JarvisManageError {}
let authorized = try JSONDecoder().decode(JarvisAuthorizedContext.self, from: Data(#"{"schema_version":1,"scope":"recent_excerpt","sources":[{"source_id":"channel:7:2","peer_type":"channel","peer_id":7,"message_id":2,"text":"Proposal","truncated":false}]}"#.utf8))
check(authorized.evidence(sourceId: "channel:8:9") == nil, "Model invented evidence became clickable")
check(authorized.prompt.contains("channel:7:2"), "Context lost evidence ID")
