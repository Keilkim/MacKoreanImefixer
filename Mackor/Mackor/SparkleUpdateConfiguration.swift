import Foundation

/// Non-secret Sparkle settings embedded in the built app's Info.plist.
///
/// Release builds provide these values through Xcode build settings. Keeping
/// validation separate from Sparkle lets local builds stay inert when release
/// infrastructure has not supplied a feed or public key yet.
struct SparkleUpdateConfiguration: Equatable {
    enum ConfigurationError: Error, Equatable {
        case missingFeedURL
        case invalidFeedURL
        case missingPublicEDKey
        case invalidPublicEDKey
    }

    static let feedURLInfoKey = "SUFeedURL"
    static let publicEDKeyInfoKey = "SUPublicEDKey"

    let feedURL: URL
    let publicEDKey: String

    init(infoDictionary: [String: Any]?) throws {
        guard let rawFeedURL = Self.configuredString(
            in: infoDictionary,
            key: Self.feedURLInfoKey
        ) else {
            throw ConfigurationError.missingFeedURL
        }

        guard let components = URLComponents(string: rawFeedURL),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil,
              let feedURL = components.url else {
            throw ConfigurationError.invalidFeedURL
        }

        guard let publicEDKey = Self.configuredString(
            in: infoDictionary,
            key: Self.publicEDKeyInfoKey
        ) else {
            throw ConfigurationError.missingPublicEDKey
        }

        guard let publicKeyData = Data(base64Encoded: publicEDKey),
              publicKeyData.count == 32 else {
            throw ConfigurationError.invalidPublicEDKey
        }

        self.feedURL = feedURL
        self.publicEDKey = publicEDKey
    }

    private static func configuredString(
        in infoDictionary: [String: Any]?,
        key: String
    ) -> String? {
        guard let value = infoDictionary?[key] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains("$("),
              !trimmed.contains("${") else {
            return nil
        }
        return trimmed
    }
}
