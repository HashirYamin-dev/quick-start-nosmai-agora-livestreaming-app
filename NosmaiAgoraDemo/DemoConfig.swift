import Foundation

/// All the keys this demo needs. Replace the values below with your own.
///
/// - Nosmai API key: from your Nosmai dashboard. It is tied to the app's bundle
///   identifier, so the bundle ID in Xcode must match the one registered for the key.
/// - Agora App ID / token: from https://console.agora.io. A temporary token is
///   generated for one specific channel name, so `agoraChannel` must match it.
///   Leave `agoraToken` empty if your Agora project has no App Certificate.
struct DemoConfig {
    static let nosmaiAPIKey = "YOUR_NOSMAI_API_KEY"
    static let agoraAppID = "YOUR_AGORA_APP_ID"
    static let agoraChannel = "demo-channel"
    static let agoraToken = "YOUR_AGORA_TEMP_TOKEN"

    let nosmaiAPIKey: String
    let agoraAppID: String
    let channel: String
    /// nil joins without a token (Agora projects in testing mode).
    let token: String?

    /// Returns the config, or a human readable reason when a key is still missing.
    static func load() -> Result<DemoConfig, ConfigError> {
        func clean(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let config = DemoConfig(nosmaiAPIKey: clean(nosmaiAPIKey),
                                agoraAppID: clean(agoraAppID),
                                channel: clean(agoraChannel),
                                token: clean(agoraToken).isEmpty ? nil : clean(agoraToken))
        if config.token?.hasPrefix("YOUR_") == true {
            return .failure(.init(message: "Set agoraToken in DemoConfig.swift (or leave it empty)."))
        }
        if config.nosmaiAPIKey.isEmpty || config.nosmaiAPIKey.hasPrefix("YOUR_") {
            return .failure(.init(message: "Set nosmaiAPIKey in DemoConfig.swift."))
        }
        if config.agoraAppID.hasPrefix("YOUR_") || config.agoraAppID.count != 32 {
            return .failure(.init(message: "Set your 32-character agoraAppID in DemoConfig.swift."))
        }
        if config.channel.isEmpty { return .failure(.init(message: "Set agoraChannel in DemoConfig.swift.")) }
        return .success(config)
    }

    struct ConfigError: Error { let message: String }
}
