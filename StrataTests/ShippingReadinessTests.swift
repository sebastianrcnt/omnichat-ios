import Foundation
import Testing
@testable import Strata

struct ShippingReadinessTests {
    private func manifest(_ bundle: Bundle) throws -> [String: Any] {
        let url = try #require(bundle.url(forResource: "PrivacyInfo", withExtension: "xcprivacy"))
        return try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func reasons(_ manifest: [String: Any]) throws -> [String: [String]] {
        let entries = try #require(manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]])
        return try Dictionary(uniqueKeysWithValues: entries.map {
            (try #require($0["NSPrivacyAccessedAPIType"] as? String), try #require($0["NSPrivacyAccessedAPITypeReasons"] as? [String]))
        })
    }

    @Test func appManifestDeclaresOnlyTheAPIsTheAppUses() throws {
        let data = try manifest(.main)
        #expect(data["NSPrivacyTracking"] as? Bool == false)
        #expect((data["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        #expect(try reasons(data) == [
            "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1"],
            "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"],
            "NSPrivacyAccessedAPICategorySystemBootTime": ["35F9.1"],
        ])
        #expect(!(Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []).contains("audio"))
    }

    @Test func shareExtensionHasItsOwnTimestampManifest() throws {
        let plugins = try #require(Bundle.main.builtInPlugInsURL)
        let urls = try FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil)
        let bundle = try #require(urls.compactMap(Bundle.init(url:)).first { $0.bundleIdentifier == "cc.coolservices.strata.share" })
        let data = try manifest(bundle)
        #expect(data["NSPrivacyTracking"] as? Bool == false)
        #expect((data["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        #expect(try reasons(data) == ["NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1"]])
    }

    @Test func healthAvailabilityMatchesTheBuildsPermissionMetadata() {
        #expect(HealthSettings.isSupported == (Bundle.main.object(forInfoDictionaryKey: "NSHealthShareUsageDescription") != nil))
    }
}
