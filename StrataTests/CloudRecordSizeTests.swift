import CloudKit
import CoreData
import Foundation
import SwiftData
import Testing
@testable import Strata

@MainActor
struct CloudRecordSizeTests {
    private let mb = 1_000_000

    private func container() throws -> ModelContainer {
        try ModelContainer(for: StrataStore.schema, configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }

    /// One of each synced model, by entity name.
    private func samples() throws -> [String: any CloudSized] {
        let compaction = try CompactionRecord(anchorMessageID: UUID(), notes: "n", replacement: [], tokensBefore: 0, tokensAfter: 0,
                                              isAutomatic: true)
        return ["Conversation": Conversation(), "Message": Message(role: .user, sortIndex: 0),
                "Attachment": Attachment(jpegData: Data(), sortIndex: 0, thumbnailData: nil), "CompactionRecord": compaction,
                "SyncedSkill": SyncedSkill(Skill(name: "s", description: "d", body: "b")),
                "SyncedFile": SyncedFile(path: "p", conversationID: nil, data: Data())]
    }

    /// The estimate knows every value Core Data sizes, so a new String or Data attribute can't slip past it.
    @Test func everyGrowingAttributeOfEverySyncedModelIsCounted() throws {
        let model = try #require(NSManagedObjectModel.makeManagedObjectModel(for: StrataStore.models))
        let samples = try samples()
        #expect(Set(model.entities.compactMap(\.name)) == Set(samples.keys))
        for entity in model.entities {
            let sample = try #require(samples[entity.name ?? ""])
            let growing = entity.attributesByName.filter { [.stringAttributeType, .binaryDataAttributeType].contains($0.value.attributeType) }
            #expect(Set(growing.keys) == Set(sample.cloudFields.keys), "\(entity.name ?? "")")
            // Anything else would be a kind of value the estimate doesn't model (transformable, composite).
            let fixed: Set<NSAttributeType> = [.stringAttributeType, .binaryDataAttributeType, .UUIDAttributeType, .dateAttributeType,
                                               .booleanAttributeType, .integer16AttributeType, .integer32AttributeType,
                                               .integer64AttributeType, .doubleAttributeType, .floatAttributeType]
            for (name, attribute) in entity.attributesByName {
                #expect(fixed.contains(attribute.attributeType), "\(entity.name ?? "").\(name)")
            }
        }
    }

    @Test func dataOfAnySizeMovesToAnAssetAndTheRecordFits() throws {
        let store = try container()
        let context = store.mainContext
        let m = Message(role: .assistant, text: String(repeating: "a", count: 200_000), sortIndex: 0)
        context.insert(m)
        m.stepsData = Data(count: 8 * mb)
        m.segmentsData = Data(count: 2 * mb)
        m.resumeData = Data(count: 6 * mb)
        m.resumeDynamicData = Data(count: 3 * mb)
        m.openUIStateData = Data(count: 900_000)
        try context.save()
        #expect(m.fitsCloudRecord)
        // The role and the text (the smallest) stay inline; each blob goes to its asset.
        #expect(m.cloudInlineBytes == CloudRecordSize.overhead + "assistant".utf8.count + 200_000 + 5 * CloudRecordSize.assetReference)
    }

    @Test func blobsJustBelowTheSpillPointStayInlineButTheTotalFits() {
        // Two 400 KB values: the first stays inline, the second would pass 700,000 and moves.
        let inline = CloudRecordSize.inlineBytes([CloudRecordSize.Field(Data(count: 400_000)), CloudRecordSize.Field(Data(count: 400_000))])
        #expect(inline == CloudRecordSize.overhead + 400_000 + CloudRecordSize.assetReference)
        #expect(CloudRecordSize.fits(inlineBytes: inline))
    }

    @Test func asciiTextOfAnySizeFits() {
        let m = Message(role: .user, text: String(repeating: "a", count: 3 * mb), sortIndex: 0)
        #expect(m.fitsCloudRecord)
        #expect(m.cloudInlineBytes < 10_000)
    }

    /// Core Data counts text in UTF-16 units: 400,000 Korean syllables count as 400 KB and stay inline, but weigh 1.2 MB.
    @Test func koreanTextBelowTheSpillPointIsTooLarge() {
        let m = Message(role: .user, text: String(repeating: "가", count: 400_000), sortIndex: 0)
        #expect(m.cloudInlineBytes > 1_200_000)
        #expect(!m.fitsCloudRecord)
    }

    @Test func koreanTextPastTheSpillPointMovesToAnAsset() {
        let m = Message(role: .user, text: String(repeating: "가", count: 800_000), sortIndex: 0)
        #expect(m.fitsCloudRecord)
    }

    /// The largest records the app writes in practice still fit, with the margin.
    @Test func realisticWorstCasesFit() throws {
        // A long Korean answer (about 128K output tokens), English reasoning, a checkpoint and tool results.
        let answer = Message(role: .assistant, text: String(repeating: "가나다 ", count: 50_000), sortIndex: 1)
        answer.reasoning = String(repeating: "thinking ", count: 30_000)
        answer.stepsData = Data(count: 5 * mb)
        answer.resumeDynamicData = Data(count: 2 * mb)
        answer.errorText = String(repeating: "오류", count: 5_000)
        #expect(answer.fitsCloudRecord)
        // An English answer at the output limit with its Korean translation: the larger one moves to an asset.
        let translated = Message(role: .assistant, text: String(repeating: "word ", count: 100_000), sortIndex: 2)
        translated.translatedText = String(repeating: "단어 ", count: 80_000)
        #expect(translated.fitsCloudRecord)
        // A skill at its body limit, all Korean.
        let skill = SyncedSkill(Skill(name: "s", description: String(repeating: "설", count: Skill.descriptionLimit),
                                      body: String(repeating: "본", count: Skill.bodyLimit)))
        #expect(skill.fitsCloudRecord)
        // A conversation with long frozen prompts and many sources.
        let conversation = Conversation(title: String(repeating: "제", count: 200))
        conversation.preferencesSnapshot = String(repeating: "선호", count: 20_000)
        conversation.skillIndexSnapshot = String(repeating: "기술", count: 20_000)
        conversation.pluginSectionSnapshot = String(repeating: "p", count: 20_000)
        conversation.sourcesData = Data(count: 3 * mb)
        #expect(conversation.fitsCloudRecord)
        let compaction = try CompactionRecord(anchorMessageID: UUID(), notes: String(repeating: "요약", count: 30_000),
                                              replacement: [], tokensBefore: 0, tokensAfter: 0, isAutomatic: true)
        compaction.replacementData = Data(count: 4 * mb)
        #expect(compaction.fitsCloudRecord)
    }

    @Test func diagnosticsNameRecordsTooLargeForICloud() throws {
        let store = try container()
        let context = store.mainContext
        let c = Conversation(title: "t")
        context.insert(c)
        let small = Message(role: .user, text: "hi", sortIndex: 0)
        let large = Message(role: .assistant, text: String(repeating: "가", count: 400_000), sortIndex: 1)
        for m in [small, large] { context.insert(m); m.conversation = c }
        try context.save()
        let d = ConversationDiagnostics.make(for: c, window: 1000, ring: RequestRing(), counters: DiagnosticCounters())
        #expect(d.storage.cloudRecordsTooLarge == 1)
        #expect(d.storage.largestCloudRecordBytes == large.cloudInlineBytes)
    }

    @Test func aRecordRefusedAsTooLargeIsNamedInSettings() {
        let id = CKRecord.ID(recordName: "r")
        let partial = CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: [id: CKError(.limitExceeded)]])
        #expect(CloudSync.describe(partial).contains("too large for iCloud"))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: 134_400, userInfo: [NSUnderlyingErrorKey: CKError(.limitExceeded)])
        #expect(CloudSync.describe(wrapped).contains("too large for iCloud"))
        let other = CKError(.networkUnavailable)
        #expect(CloudSync.describe(other) == other.localizedDescription)
    }
}
