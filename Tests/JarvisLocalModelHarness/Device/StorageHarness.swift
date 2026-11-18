import Foundation
import UIKit
import Security

// Isolated simulator app: synthetic credentials only, no network operations.
@main
final class StorageHarness: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool { return true }
}

@objc(StorageSceneDelegate)
final class StorageSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        self.window = window
        window.makeKeyAndVisible()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.runChecks() }
    }
    private func runChecks() {
        let probe = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "im.talky.jarvis.storageharness.probe"] as CFDictionary)
        print("JARVIS_KEYCHAIN_PROBE_STATUS=\(probe)")
        var stage = "initialization"
        do {
            let first = try JarvisLocalKeyStore(userId: 919159001)
            let other = try JarvisLocalKeyStore(userId: 919159002)
            stage = "initial cleanup"
            try first.delete()
            try other.delete()
            defer { try? first.delete(); try? other.delete() }
            let credential = try JarvisLocalCredential(provider: .openai, model: "synthetic-model", key: "synthetic-storage-only")
            stage = "save"
            try first.save(credential)
            stage = "load"
            guard let loaded = try JarvisLocalKeyStore(userId: 919159001).load() else { fatalError("Keychain round trip failed") }
            let request = try JarvisLocalModelClient.request(credential: loaded, context: "", question: "Synthetic check")
            guard request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-storage-only" else { fatalError("Keychain content mismatch") }
            guard try other.load() == nil else { fatalError("Account isolation failed") }
            let replacement = try JarvisLocalCredential(provider: .deepseek, model: "replacement-model", key: "synthetic-replacement")
            stage = "update"
            try first.save(replacement)
            guard let updated = try first.load(), updated.provider == .deepseek else { fatalError("Keychain update failed") }
            stage = "custom round trip"
            let custom = try JarvisLocalCredential(provider: .custom, format: .anthropic,
                                                   baseUrl: "https://gateway.example/v1",
                                                   models: ["model-a", "model-b"], model: "model-b",
                                                   key: "synthetic-custom")
            try first.save(custom)
            guard let reloaded = try first.load(),
                  reloaded.provider == .custom,
                  reloaded.format == .anthropic,
                  reloaded.baseUrl == "https://gateway.example/v1",
                  reloaded.models == ["model-a", "model-b"],
                  reloaded.model == "model-b",
                  reloaded.endpoint.absoluteString == "https://gateway.example/v1/messages" else {
                fatalError("Keychain custom credential mismatch")
            }
            try first.delete()
            guard try first.load() == nil else { fatalError("Keychain deletion failed") }
            try first.delete()
            print("JARVIS_KEYCHAIN_DEVICE_TEST_PASS")
            fflush(stdout)
            exit(0)
        } catch {
            // Never log underlying credential errors or values.
            print("JARVIS_KEYCHAIN_DEVICE_TEST_FAIL stage=\(stage)")
            fflush(stdout)
            exit(1)
        }
    }
}
