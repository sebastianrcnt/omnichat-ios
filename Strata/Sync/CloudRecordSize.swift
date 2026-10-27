import Foundation

/// Whether a synced record fits CloudKit's 1 MB record limit (assets don't count toward it).
///
/// Core Data (`PFCloudKitSerializer`, as read from the macOS 27 framework) gives every String and Binary Data
/// attribute a second field, `CD_<name>_ckAsset`. It adds a record's values from the smallest up and moves a value into
/// its asset field once the record's running size plus the value would pass 700,000; otherwise the value stays inline.
/// `.externalStorage` plays no part in it (it only decides where the local store keeps the bytes), so Data of any size
/// can't push a record past the limit.
///
/// Text can: the running size counts a string by its UTF-16 length, but it travels as UTF-8, three bytes a unit for
/// Korean, Chinese or Japanese. Up to 700,000 units of such text stay inline, about 2 MB. `inlineBytes` replays the
/// rule with the real sizes so diagnostics can name a record CloudKit would refuse; that record still saves on this
/// device, it just doesn't sync.
enum CloudRecordSize {
    /// One String or Data value: what Core Data counts it as, and what it weighs on the wire.
    struct Field: Equatable, Sendable {
        var counted: Int
        var bytes: Int

        init(_ text: String?) {
            counted = text?.utf16.count ?? 0
            bytes = text?.utf8.count ?? 0
        }

        init(_ data: Data?) {
            counted = data?.count ?? 0
            bytes = counted
        }
    }

    static let limit = 1_000_000
    /// Core Data moves a value to its asset once the record would count more than this.
    static let spillPoint = 700_000
    /// The record's system fields, ids, dates, numbers and references: a generous allowance.
    static let overhead = 4_096
    /// What an asset field costs inline.
    static let assetReference = 256
    /// Kept free below `limit`, for what the estimate can't see.
    static let margin = 64 * 1024

    /// Bytes the record carries inline once Core Data moved what it moves into assets.
    static func inlineBytes<S: Sequence>(_ fields: S) -> Int where S.Element == Field {
        var counted = overhead, bytes = overhead
        for field in fields.sorted(by: { $0.counted < $1.counted }) where field.counted > 0 {
            if counted + field.counted > spillPoint {
                bytes += assetReference
            } else {
                counted += field.counted
                bytes += field.bytes
            }
        }
        return bytes
    }

    static func fits(inlineBytes: Int) -> Bool { inlineBytes <= limit - margin }
}

/// A synced model, by the String and Data attributes Core Data may move to assets.
protocol CloudSized {
    /// Every String and Data attribute by name (`CloudRecordSizeTests` checks the names against the schema).
    var cloudFields: [String: CloudRecordSize.Field] { get }
}

extension CloudSized {
    var cloudInlineBytes: Int { CloudRecordSize.inlineBytes(cloudFields.values) }
    var fitsCloudRecord: Bool { CloudRecordSize.fits(inlineBytes: cloudInlineBytes) }
}

extension Conversation: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["title": .init(title), "createdDay": .init(createdDay), "modelID": .init(modelID), "effortRaw": .init(effortRaw),
         "syncOrigin": .init(syncOrigin), "preferencesSnapshot": .init(preferencesSnapshot),
         "skillIndexSnapshot": .init(skillIndexSnapshot), "pluginSectionSnapshot": .init(pluginSectionSnapshot),
         "toolSwitchesRaw": .init(toolSwitchesRaw), "offeredToolsRaw": .init(offeredToolsRaw),
         "announcedToolsRaw": .init(announcedToolsRaw), "sourcesData": .init(sourcesData),
         "packageSnapshotData": .init(packageSnapshotData)]
    }
}

extension Message: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["roleRaw": .init(roleRaw), "text": .init(text), "reasoning": .init(reasoning), "errorText": .init(errorText),
         "resumeData": .init(resumeData), "resumeDynamicData": .init(resumeDynamicData),
         "resumeDeviceID": .init(resumeDeviceID), "translatedText": .init(translatedText),
         "translationTarget": .init(translationTarget), "apiNote": .init(apiNote), "stepsData": .init(stepsData),
         "segmentsData": .init(segmentsData), "openUIStateData": .init(openUIStateData)]
    }
}

extension Attachment: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["jpegData": .init(jpegData), "thumbnailData": .init(thumbnailData)]
    }
}

extension CompactionRecord: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["notes": .init(notes), "replacementData": .init(replacementData)]
    }
}

extension SyncedSkill: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["name": .init(name), "summary": .init(summary), "body": .init(body), "origin": .init(origin)]
    }
}

extension SyncedFile: CloudSized {
    var cloudFields: [String: CloudRecordSize.Field] {
        ["path": .init(path), "data": .init(data), "origin": .init(origin)]
    }
}
