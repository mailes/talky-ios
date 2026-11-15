import Foundation
import CryptoKit

@available(iOS 13.0, macOS 10.15, *)
public enum JarvisSessionTicket {
    // Shared wire contract with server realtime/ticket.go and Android's native bridge.
    public static func make(authKey: Data, authKeyId: UInt64, userId: Int64, expires: Int64) -> String? {
        guard authKey.count == 256, userId > 0, expires > 0 else { return nil }
        let payload = Data("v1:\(authKeyId):\(userId):\(expires)".utf8)
        var input = Data("talky-jarvis-realtime-ticket-v1".utf8)
        input.append(0)
        input.append(payload)
        let signature = Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: authKey)))
        func base64(_ data: Data) -> String {
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        return base64(payload) + "." + base64(signature)
    }
}
