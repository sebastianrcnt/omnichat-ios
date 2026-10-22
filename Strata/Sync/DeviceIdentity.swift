import Foundation
#if os(iOS)
import UIKit
#endif

/// This installation's id. Synced records carry it where two devices must tell their copies apart the same way
/// (`Conversation.syncOrigin`, `Message.resumeDeviceID`). Never shown and never sent anywhere but iCloud.
enum DeviceIdentity {
    static let defaultsKey = "sync.deviceID"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cached: String?

    static var current: String {
        lock.withLock {
            if let cached { return cached }
            let id = stored(UserDefaults.standard)
            cached = id
            return id
        }
    }

    /// Called first thing at launch. On iPhone the id is the vendor id, which a backup restored onto another iPhone does
    /// not bring along (UserDefaults would, and both phones would then claim the same records).
    @MainActor
    static func prime() {
        #if os(iOS)
        guard let vendor = UIDevice.current.identifierForVendor?.uuidString else { return }
        lock.withLock { cached = vendor }
        #endif
    }

    /// A UUID chosen once and kept in `defaults`.
    static func stored(_ defaults: UserDefaults) -> String {
        if let id = defaults.string(forKey: defaultsKey), !id.isEmpty { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: defaultsKey)
        return id
    }
}
