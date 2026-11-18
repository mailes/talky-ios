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
let answer = try JarvisLocalModelClient.response(format: .openai, status: 200, data: validResponse)
check(answer.contains("channel:7:2"), "Lost answer evidence")
let anthropicResponse = Data(#"{"content":[{"type":"text","text":"First"},{"type":"tool_use","id":"x"},{"type":"text","text":"Second"}]}"#.utf8)
let anthropicAnswer = try JarvisLocalModelClient.response(format: .anthropic, status: 200, data: anthropicResponse)
check(anthropicAnswer == "First\nSecond", "Lost Anthropic text parts")
let geminiResponse = Data(#"{"candidates":[{"content":{"parts":[{"text":"Gemini answer"}]}}]}"#.utf8)
let geminiAnswer = try JarvisLocalModelClient.response(format: .gemini, status: 200, data: geminiResponse)
check(geminiAnswer == "Gemini answer", "Lost Gemini text parts")
for status in [301, 401, 403, 429, 500] {
    expectFailure("Provider error accepted") { _ = try JarvisLocalModelClient.response(format: .openai, status: status, data: Data("private-provider-error".utf8)) }
}
expectFailure("Invalid JSON accepted") { _ = try JarvisLocalModelClient.response(format: .openai, status: 200, data: Data("invalid".utf8)) }
expectFailure("Tool calls accepted") { _ = try JarvisLocalModelClient.response(format: .openai, status: 200, data: Data(#"{"choices":[{"message":{"content":"done","tool_calls":[]}}]}"#.utf8)) }
expectFailure("Empty Anthropic answer accepted") { _ = try JarvisLocalModelClient.response(format: .anthropic, status: 200, data: Data(#"{"content":[{"type":"tool_use","id":"x"}]}"#.utf8)) }
print("Jarvis local model iOS core checks passed")

// MARK: - Providers, formats and custom endpoints (Android parity)

let anthropic = try JarvisLocalCredential(provider: .anthropic, model: "claude-3-5-haiku-latest", key: "synthetic-anthropic-key")
let anthropicRequest = try JarvisLocalModelClient.request(credential: anthropic, context: "[channel:7:2] Evidence", question: "Anything?")
check(anthropicRequest.url?.absoluteString == "https://api.anthropic.com/v1/messages", "Wrong Anthropic endpoint")
check(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "synthetic-anthropic-key", "Missing Anthropic key header")
check(anthropicRequest.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "Missing Anthropic version")
check(anthropicRequest.value(forHTTPHeaderField: "Authorization") == nil, "Anthropic must not use Bearer")
let anthropicBody = try JSONSerialization.jsonObject(with: anthropicRequest.httpBody!) as! [String: Any]
check((anthropicBody["system"] as? String)?.contains("untrusted data") == true, "Anthropic system prompt lost")
check((anthropicBody["messages"] as? [[String: Any]])?.first?["role"] as? String == "user", "Anthropic messages lost")
check(anthropicBody["max_tokens"] as? Int == 2048, "Anthropic token limit lost")

let gemini = try JarvisLocalCredential(provider: .gemini, model: "gemini-2.0-flash", key: "synthetic-gemini-key")
let geminiRequest = try JarvisLocalModelClient.request(credential: gemini, context: "", question: "Hello")
check(geminiRequest.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:generateContent", "Wrong Gemini endpoint")
check(geminiRequest.value(forHTTPHeaderField: "x-goog-api-key") == "synthetic-gemini-key", "Missing Gemini key header")
check(geminiRequest.value(forHTTPHeaderField: "Authorization") == nil, "Gemini must not use Bearer")
let geminiBody = try JSONSerialization.jsonObject(with: geminiRequest.httpBody!) as! [String: Any]
check((geminiBody["contents"] as? [[String: Any]])?.first?["parts"] != nil, "Gemini contents lost")
check(geminiBody["generationConfig"] != nil, "Gemini generation config lost")

let custom = try JarvisLocalCredential(provider: .custom, format: .openai,
                                       baseUrl: "https://gateway.example/v1/",
                                       models: ["model-a", "model-a", "model-b"], model: "model-b",
                                       key: "synthetic-custom-key")
check(custom.baseUrl == "https://gateway.example/v1", "Base URL trailing slash kept")
check(custom.models == ["model-a", "model-b"], "Models not de-duplicated")
check(custom.model == "model-b", "Selected model lost")
check(custom.endpoint.absoluteString == "https://gateway.example/v1/chat/completions", "Wrong custom endpoint")
let updated = try custom.updating(provider: .custom, format: .anthropic, baseUrl: "http://localhost:8080/messages",
                                  models: ["model-b"], model: "model-b")
check(updated.isCleartext, "Cleartext endpoint not detected")
check(updated.endpoint.absoluteString == "http://localhost:8080/messages", "Anthropic suffix duplicated")
let updatedRequest = try JarvisLocalModelClient.request(credential: updated, context: "", question: "Hello")
check(updatedRequest.value(forHTTPHeaderField: "x-api-key") == "synthetic-custom-key", "Updating lost the saved key")

expectFailure("Missing scheme accepted") { _ = try JarvisLocalCredential(provider: .custom, format: .openai, baseUrl: "api.example.com", models: ["m"], model: "m", key: "k") }
expectFailure("Base URL with whitespace accepted") { _ = try JarvisLocalCredential(provider: .custom, format: .openai, baseUrl: "https://exa mple.com", models: ["m"], model: "m", key: "k") }
expectFailure("Model with whitespace accepted") { _ = try JarvisLocalCredential(provider: .openai, format: .openai, baseUrl: "https://api.openai.com/v1", models: ["bad model"], model: "bad model", key: "k") }
expectFailure("Empty model list accepted") { _ = try JarvisLocalCredential(provider: .openai, format: .openai, baseUrl: "https://api.openai.com/v1", models: [], model: "m", key: "k") }

let legacy = try JSONDecoder().decode(JarvisLocalCredential.self, from: Data(#"{"provider":"deepseek","model":"deepseek-chat","key":"synthetic-legacy-key"}"#.utf8))
check(legacy.format == .openai, "Legacy format not derived")
check(legacy.baseUrl == "https://api.deepseek.com", "Legacy base URL not derived")
check(legacy.models == ["deepseek-chat"], "Legacy models not derived")
let legacyRequest = try JarvisLocalModelClient.request(credential: legacy, context: "", question: "Hello")
check(legacyRequest.url?.absoluteString == "https://api.deepseek.com/chat/completions", "Legacy endpoint changed")
let roundTrip = try JSONDecoder().decode(JarvisLocalCredential.self, from: JSONEncoder().encode(anthropic))
check(roundTrip == anthropic, "Credential round trip lost fields")
print("Jarvis local provider checks passed")

// MARK: - Answer rendering (shared with the Android renderer)

check(jarvisMarkdownSpans("**HELLO** and `code`") == [
    JarvisMarkdownSpan(text: "HELLO", kind: .bold),
    JarvisMarkdownSpan(text: " and ", kind: nil),
    JarvisMarkdownSpan(text: "code", kind: .code)
], "Bold or code span lost")
check(jarvisMarkdownSpans("An *emphasis* here") == [
    JarvisMarkdownSpan(text: "An ", kind: nil),
    JarvisMarkdownSpan(text: "emphasis", kind: .italic),
    JarvisMarkdownSpan(text: " here", kind: nil)
], "Italic span lost")
check(jarvisMarkdownSpans("**wrapped\nlines**") == [
    JarvisMarkdownSpan(text: "wrapped\nlines", kind: .bold)
], "Multiline bold lost")
check(jarvisMarkdownSpans("## Heading\nBody") == [
    JarvisMarkdownSpan(text: "Heading\nBody", kind: nil)
], "Heading markers kept")
check(jarvisMarkdownSpans("See [channel:13:5] and [channel:13:6]") == [
    JarvisMarkdownSpan(text: "See [channel:13:5] and [channel:13:6]", kind: nil)
], "Citation brackets eaten")
check(jarvisMarkdownSpans("no markers") == [
    JarvisMarkdownSpan(text: "no markers", kind: nil)
], "Plain answer changed")
print("Jarvis answer rendering checks passed")

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

for command in ["/setkey", "/setkey@jarvis", "/setkey deepseek sk-synthetic", "  /setkey  "] {
    check(JarvisCommandText.isSetKeyCommand(command), "Missed /setkey command: \(command)")
}
for text in ["/setkeyfoo", "hello /setkey", "/set key", "", "/setkey custom https://example model synthetic", "/setkey@jarvis custom https://example model synthetic"] {
    check(!JarvisCommandText.isSetKeyCommand(text), "Swallowed ordinary text or custom command: \(text)")
}
let validation = try JarvisLocalModelClient.validationRequest(credential: credential)
check(validation.url?.host == "api.openai.com", "Validation must go only to the provider")
let validationBody = try JSONSerialization.jsonObject(with: validation.httpBody!) as! [String: Any]
check(validationBody["max_tokens"] as? Int == 1, "Validation must be minimal")
check(validationBody["key"] == nil, "Credential leaked into validation body")

let capabilitiesRequest = try JarvisManageRequest.capabilities(origin: URL(string: "https://service.example")!, ticket: "session")
check(capabilitiesRequest.httpMethod == "GET", "Capabilities must be a read")
check(capabilitiesRequest.url!.query!.contains("action=model_capabilities"), "Wrong capabilities action")
let overviewRequest = try JarvisManageRequest.overview(origin: URL(string: "https://service.example")!, ticket: "session")
check(overviewRequest.httpMethod == "GET", "Overview must be a read")
let hostedKeyRequest = try JarvisManageRequest.hostedKey(origin: URL(string: "https://service.example")!, ticket: "session", provider: "deepseek", model: "deepseek-chat", key: "synthetic-hosted-key")
check(hostedKeyRequest.httpMethod == "POST", "Hosted key must be a write")
check(hostedKeyRequest.url!.query!.contains("action=hosted_key"), "Wrong hosted key action")
check(!hostedKeyRequest.url!.absoluteString.contains("synthetic-hosted-key"), "Hosted key leaked into URL")
let hostedBody = try JSONSerialization.jsonObject(with: hostedKeyRequest.httpBody!) as! [String: Any]
check(hostedBody["provider"] as? String == "deepseek", "Hosted provider lost")
check(hostedBody["key"] as? String == "synthetic-hosted-key", "Hosted key missing from body")
let grantRequest = try JarvisManageRequest.grant(origin: URL(string: "https://service.example")!, ticket: "session", peerId: 7)
check(grantRequest.httpMethod == "POST", "Grant must be a write")
check(grantRequest.url!.query!.contains("peer_id=7"), "Grant lost peer id")
check(!grantRequest.url!.absoluteString.contains("session"), "Ticket leaked into URL")
check(JarvisManageRequest.trustedOrigin("http://service.example") == nil, "Insecure origin accepted")
check(JarvisManageRequest.trustedOrigin("https://service.example/path") == nil, "Origin with path accepted")
