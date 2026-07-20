import XCTest

final class SparkleUpdateConfigurationTests: XCTestCase {
    private let validFeedURL = "https://updates.example.com/mackor/appcast.xml"
    private let validPublicKey = Data(repeating: 0x2A, count: 32).base64EncodedString()

    func testAcceptsHTTPSFeedAndEd25519PublicKey() throws {
        let configuration = try SparkleUpdateConfiguration(infoDictionary: [
            SparkleUpdateConfiguration.feedURLInfoKey: validFeedURL,
            SparkleUpdateConfiguration.publicEDKeyInfoKey: validPublicKey,
        ])

        XCTAssertEqual(configuration.feedURL.absoluteString, validFeedURL)
        XCTAssertEqual(configuration.publicEDKey, validPublicKey)
    }

    func testEmptyBuildSettingValuesKeepUpdaterDisabled() {
        XCTAssertThrowsError(try SparkleUpdateConfiguration(infoDictionary: [
            SparkleUpdateConfiguration.feedURLInfoKey: "",
            SparkleUpdateConfiguration.publicEDKeyInfoKey: "",
        ])) { error in
            XCTAssertEqual(
                error as? SparkleUpdateConfiguration.ConfigurationError,
                .missingFeedURL
            )
        }
    }

    func testUnexpandedBuildSettingIsNotTreatedAsConfiguration() {
        XCTAssertThrowsError(try SparkleUpdateConfiguration(infoDictionary: [
            SparkleUpdateConfiguration.feedURLInfoKey: "$(MACKOR_UPDATE_FEED_URL)",
            SparkleUpdateConfiguration.publicEDKeyInfoKey: validPublicKey,
        ])) { error in
            XCTAssertEqual(
                error as? SparkleUpdateConfiguration.ConfigurationError,
                .missingFeedURL
            )
        }
    }

    func testRejectsInsecureFeedURL() {
        XCTAssertThrowsError(try SparkleUpdateConfiguration(infoDictionary: [
            SparkleUpdateConfiguration.feedURLInfoKey:
                "http://updates.example.com/mackor/appcast.xml",
            SparkleUpdateConfiguration.publicEDKeyInfoKey: validPublicKey,
        ])) { error in
            XCTAssertEqual(
                error as? SparkleUpdateConfiguration.ConfigurationError,
                .invalidFeedURL
            )
        }
    }

    func testRejectsPublicKeyWithWrongDecodedLength() {
        let shortKey = Data(repeating: 0x2A, count: 31).base64EncodedString()

        XCTAssertThrowsError(try SparkleUpdateConfiguration(infoDictionary: [
            SparkleUpdateConfiguration.feedURLInfoKey: validFeedURL,
            SparkleUpdateConfiguration.publicEDKeyInfoKey: shortKey,
        ])) { error in
            XCTAssertEqual(
                error as? SparkleUpdateConfiguration.ConfigurationError,
                .invalidPublicEDKey
            )
        }
    }
}
