import Foundation
import SwiftData
import Observation

// `health_query`: reads Apple Health for the user's own questions about their health. Read-only. The first read of a
// type asks in a card under the call's line, then iOS shows its sheet. Nothing here is stored beyond the chat itself,
// and the results are masked in debug bundles (`DebugRedaction`).

extension ToolNames {
    static let healthQuery = "health_query"
}

extension ToolDefinition {
    static let healthQuery = ToolDefinition(function: .init(
        name: ToolNames.healthQuery,
        description: "Read the user's Apple Health data (read-only) to answer their questions about their own activity, sleep, heart, body measurements and workouts. Returns compact tables: a row per day (sleep: per night, with stages), week or month, or one summary, with units. The first read of a type asks the user for permission. Use list_available to see which types have data.",
        parameters: .init(properties: [
            "metric": .init(description: "What to read, or list_available for the types that have data.",
                            choices: HealthMetric.allCases.map(\.rawValue) + [HealthArguments.listAvailable]),
            "start": .init(description: "Optional. An ISO date (2026-10-01) or date-time, or a relative range: today, yesterday, last_night, last_7_days, last_4_weeks, last_3_months, last_1_year, this_week, last_week, this_month, last_month. Defaults to the last 7 days (longer for weight and other occasional measurements)."),
            "end": .init(description: "Optional. An ISO date (that day included) or date-time. Defaults to now."),
            "aggregation": .init(description: "Optional. daily, weekly or monthly rows, or one figure: sum, avg, min, max, latest. Defaults to daily rows (weekly or monthly when the range is long).",
                                 choices: HealthAggregation.allCases.map(\.rawValue)),
        ], required: ["metric"])))
}

extension AppPrompt {
    /// Apple Health (`health_query`): read-only, not medical advice.
    static let health = """
    - health_query reads the user's Apple Health data, read-only, for their own questions about their health and fitness. Read only what the question needs, and summarize trends in plain words rather than repeating the tables.
    - You are not a doctor: don't diagnose or give medical advice. When values look concerning (very high or low heart rate, blood pressure, blood glucose or blood oxygen, a sudden change), say so calmly and suggest talking to a healthcare professional; for an emergency, tell them to call emergency services.
    - "No data or not allowed" means OmniChat can't tell whether there is no data or the user didn't allow reading it: say both are possible.
    """
}

/// The model connection a tool call's results go to (the chat's), for checks like `HealthPrivacy`.
struct ToolDestination: Sendable, Equatable {
    var name: String
    var baseURL: URL?
    var kind: Connection.Kind

    init(name: String, baseURL: URL?, kind: Connection.Kind) {
        self.name = name
        self.baseURL = baseURL
        self.kind = kind
    }

    init(_ endpoint: Endpoint) {
        self.init(name: endpoint.connectionName, baseURL: endpoint.baseURL, kind: endpoint.kind)
    }

    init(_ connection: Connection) {
        self.init(name: connection.name, baseURL: URL(string: connection.baseURL), kind: connection.kind)
    }
}

/// Where health data may go.
enum HealthPrivacy {
    /// Whether a connection's model runs on this device or the user's own network: the one check "Only send health
    /// data to on-device or local models" makes. A loopback, private (RFC 1918, link-local, unique local IPv6) or
    /// Tailscale (100.64.0.0/10, `.ts.net`) address, or a `.local` name; Apple's on-device model always. Account
    /// connections (ChatGPT, OpenCode) and Anthropic are remote, an Anthropic proxy too (its requests end at Anthropic).
    /// Extend it here for new connection kinds.
    static func isLocal(_ destination: ToolDestination?) -> Bool {
        guard let destination else { return false }
        switch destination.kind {
        case .appleOnDevice: return true
        case .chatGPT, .openCode, .anthropic: return false
        case .openAICompatible:
            guard let host = destination.baseURL?.host(percentEncoded: false) else { return false }
            return isLocalHost(host)
        }
    }

    static func isLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") || host.hasSuffix(".ts.net") { return true }
        if let v4 = ipv4(host) {
            let (a, b) = (v4[0], v4[1])
            return a == 127 || a == 10 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168)
                || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b))
        }
        if host.contains(":") {
            if host == "::1" { return true }
            if host.hasPrefix("::ffff:"), let v4 = ipv4(String(host.dropFirst(7))) { return isLocalHost(v4.map(String.init).joined(separator: ".")) }
            let first = host.split(separator: ":", omittingEmptySubsequences: false).first.map(String.init) ?? ""
            guard let word = UInt16(first, radix: 16), !first.isEmpty else { return false }
            if word & 0xFE00 == 0xFC00 || word & 0xFFC0 == 0xFE80 { return true } // fc00::/7 unique local, fe80::/10 link-local
        }
        return false
    }

    private static func ipv4(_ host: String) -> [Int]? {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return numbers
    }
}

/// Settings > Health switches the tool reads when it runs.
enum HealthSettings {
    /// Only answer when the chat's model is local (`HealthPrivacy.isLocal`). Off by default.
    static let localOnlyKey = "healthLocalOnly"

    static var localOnly: Bool { UserDefaults.standard.bool(forKey: localOnlyKey) }

    /// The Mac has no HealthKit: the group is never offered there, and Settings has no Health page.
    static var isSupported: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// Apple Health and chat sync exclude each other on a device, so health data never goes to iCloud (App Store
    /// guideline 5.1.3(ii)). Blocked while "Sync chats and skills" is on, and while the store opened with sync keeps
    /// syncing until the next launch.
    static func blockedBySync(_ defaults: UserDefaults = .standard) -> Bool {
        StrataStore.syncEnabled(defaults) || StrataStore.openedSyncing
    }

    /// Whether chats here can offer and run `health_query`.
    static var isAvailable: Bool { isSupported && !blockedBySync() }

    /// Put in place of a `health_query` result when chat sync is turned on (`HealthRedaction`).
    static let removedResult = "Health data removed from this chat when chat sync was turned on."
}

/// Turning chat sync on removes what `health_query` read from the stored chats first, so none of it reaches iCloud:
/// each call's result becomes `HealthSettings.removedResult` in the steps sent to the model, the segments the feed shows
/// and the tool groups a compaction kept, and checkpoints holding a result are dropped (that turn can't resume). While
/// sync blocks Health, the same happens on every write (`Message.steps`, `Message.segments`, `CompactionRecord`,
/// checkpoints), so a turn that was running when sync went on can't put a result back. The replies stay.
enum HealthRedaction {
    static var isActive: Bool { forcedActive ?? HealthSettings.blockedBySync() }
    /// Tests set it instead of turning on the real chat sync switch.
    @TaskLocal static var forcedActive: Bool?

    static func mentionsHealth(_ data: Data?) -> Bool {
        guard let data else { return false }
        return data.range(of: Data(ToolNames.healthQuery.utf8)) != nil
    }

    static func redacted(_ calls: [ToolCallRecord]) -> [ToolCallRecord] {
        calls.map { call in
            guard call.name == ToolNames.healthQuery, call.result != HealthSettings.removedResult else { return call }
            var c = call
            c.result = HealthSettings.removedResult
            return c
        }
    }

    static func redacted(_ steps: [ToolStep]) -> [ToolStep] {
        steps.map { var s = $0; s.calls = redacted(s.calls); return s }
    }

    static func redacted(_ segments: [ProcessSegment]) -> [ProcessSegment] {
        segments.map { var s = $0; s.calls = redacted(s.calls); return s }
    }

    /// API messages: the answers to the assistant's `health_query` calls.
    static func redacted(_ messages: [APIMessage]) -> [APIMessage] {
        let ids = Set(messages.flatMap(\.toolCalls).filter { $0.name == ToolNames.healthQuery }.map(\.id))
        guard !ids.isEmpty else { return messages }
        return messages.map { m in
            guard m.role == "tool", let id = m.toolCallID, ids.contains(id) else { return m }
            var out = m
            out.content = .text(HealthSettings.removedResult)
            return out
        }
    }

    /// Returns how many stored copies changed (messages and compactions). Saves when it changed anything.
    @MainActor
    @discardableResult
    static func redact(_ context: ModelContext) throws -> Int {
        var changed = 0
        for message in try context.fetch(FetchDescriptor<Message>()) {
            var touched = false
            // An unfinished turn's checkpoint holds its results too; the turn just can't resume.
            if mentionsHealth(message.resumeData) || mentionsHealth(message.resumeDynamicData) {
                message.clearResume()
                touched = true
            }
            if mentionsHealth(message.stepsData) {
                let steps = message.steps, clean = redacted(steps)
                if clean != steps { message.steps = clean; touched = true }
            }
            if mentionsHealth(message.segmentsData) {
                let segments = message.segments, clean = redacted(segments)
                if clean != segments { message.segments = clean; touched = true }
            }
            if touched { changed += 1 }
        }
        for record in try context.fetch(FetchDescriptor<CompactionRecord>()) where mentionsHealth(record.replacementData) {
            let messages = record.replacement, clean = redacted(messages)
            if clean != messages, let data = try? ChatRequest.encoder.encode(clean) {
                record.replacementData = data
                changed += 1
            }
        }
        if changed > 0 { try context.save() }
        return changed
    }
}

/// The cards asking to read Apple Health, each under its call's line in its own chat (several chats can reply at once).
@MainActor
@Observable
final class HealthRequests {
    static let shared = HealthRequests()

    struct Request: Identifiable, Equatable {
        let id = UUID()
        var conversationID: UUID? = ToolContext.conversationID
        /// Call ids repeat across chats, so a call is found by chat and id.
        var callID: String? = ToolContext.callID
        var metrics: [HealthMetric]
        /// The connection the data would go to, named in the card.
        var destination: String?
    }

    private var queue: [(request: Request, answer: CheckedContinuation<Bool, Never>)] = []

    func pending(conversation: UUID?) -> [Request] { queue.map(\.request).filter { $0.conversationID == conversation } }

    func request(forCall callID: String, conversation: UUID?) -> Request? {
        queue.first { $0.request.callID == callID && $0.request.conversationID == conversation }?.request
    }

    /// Waits for the answer. A cancelled turn counts as "no".
    func ask(_ request: Request) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { cont in
                if Task.isCancelled { cont.resume(returning: false); return }
                queue.append((request, cont))
                if !AppLifecycle.isActive, let conversation = request.conversationID {
                    ReplyBackgroundExecution.notifyCompletion(title: "OmniChat", body: String(localized: "The assistant asks to read Apple Health."),
                                                              conversationID: conversation)
                }
            }
        } onCancel: {
            Task { @MainActor in self.answer(request.id, allowed: false) }
        }
    }

    /// Every waiting card answered "no" (chat sync was turned on).
    func declineAll() {
        for request in queue.map(\.request) { answer(request.id, allowed: false) }
    }

    /// Ignored for a request already answered.
    func answer(_ id: UUID, allowed: Bool) {
        guard let i = queue.firstIndex(where: { $0.request.id == id }) else { return }
        queue.remove(at: i).answer.resume(returning: allowed)
    }
}

/// Runs `health_query`: checks where the data would go, asks for permission the first time, then reads and formats.
struct HealthQueryTool {
    var source: any HealthDataSource = HealthStores.default
    var localOnly: Bool = HealthSettings.localOnly
    var destination: ToolDestination? = ToolContext.destination
    var now: Date = .now
    var calendar: Calendar = .current
    var ask: @Sendable (HealthRequests.Request) async -> Bool = { await HealthRequests.shared.ask($0) }

    func run(arguments: String, conversation: UUID? = ToolContext.conversationID, callID: String? = ToolContext.callID) async -> ToolOutput {
        let request: HealthRequest
        switch HealthArguments.parse(arguments, now: now, calendar: calendar) {
        case .failure(let problem): return ToolOutput(text: problem.message, isError: true)
        case .success(let parsed): request = parsed
        }
        guard !HealthSettings.blockedBySync() else {
            return ToolOutput(text: "Error: Apple Health is off on this device while chat sync is on, so health data never goes to iCloud. Don't try again in this chat. Tell the user they can turn off \"Sync chats and skills\" in Settings > iCloud to use Apple Health.", isError: true)
        }
        guard source.isAvailable else {
            return ToolOutput(text: "Error: Apple Health isn't available on this device. Tell the user it works in OmniChat on iPhone.", isError: true)
        }
        if localOnly && !HealthPrivacy.isLocal(destination) {
            let name = destination.map { " (\($0.name))" } ?? ""
            return ToolOutput(text: "Error: the user allows health data only for on-device or local models, and this chat's model\(name) runs on a remote server. Don't try again in this chat. Tell the user they can switch the chat to a local model, or turn off \"Only send health data to on-device or local models\" in Settings > Health.", isError: true)
        }
        if let metric = request.metric, await source.needsAuthorization(for: [metric]) {
            let allowed = await ask(HealthRequests.Request(conversationID: conversation, callID: callID, metrics: [metric], destination: destination?.name))
            guard allowed else {
                return ToolOutput(text: "Error: the user didn't allow reading Apple Health now. Answer without it, and don't ask again in this chat unless they ask.", isError: true)
            }
            do { try await source.requestAuthorization(for: [metric]) } catch {
                return ToolOutput(text: "Error: iOS couldn't ask for access to Apple Health (\(error.localizedDescription)).", isError: true)
            }
        }
        do {
            switch try await HealthReport(source: source, calendar: calendar, now: now).run(request) {
            case .text(let text): return ToolOutput(text: text)
            case .empty:
                let name = request.metric?.displayName ?? "health"
                return ToolOutput(text: "No \(name) data or not allowed: Apple Health returned nothing for \(request.rangeLabel). iOS doesn't tell apps whether the user denied reading a type, so either there is no data in that range or OmniChat isn't allowed to read it. The user can check in the Settings app > Health > Data Access & Devices > OmniChat (where they may also have shared only recent history). Try a longer range if there might be older data.")
            }
        } catch {
            return ToolOutput(text: "Error: couldn't read Apple Health: \(HealthStores.describe(error))", isError: true)
        }
    }
}

/// The feed's words for a `health_query` call.
enum HealthCallLabel {
    /// "Read sleep, last 14 days"; the running and failed forms too.
    static func title(summary: String, running: Bool, failed: Bool, declined: Bool = false, empty: Bool = false) -> String {
        if summary == HealthArguments.listAvailable {
            return running ? String(localized: "Checking Apple Health…") : failed ? String(localized: "Couldn't check Apple Health")
                : String(localized: "Checked which health data is available")
        }
        if declined { return String(localized: "Didn't read \(summary)") }
        if empty && !running && !failed { return String(localized: "No data for \(summary)") }
        return running ? String(localized: "Reading \(summary)…") : failed ? String(localized: "Couldn't read \(summary)")
            : String(localized: "Read \(summary)")
    }

    /// The call found nothing (or wasn't allowed to read it).
    static func empty(_ result: String) -> Bool { result.hasPrefix("No ") && result.contains(" data or not allowed") }

    static func declined(_ result: String) -> Bool {
        result.hasPrefix("Error: the user didn't allow") || result.hasPrefix("Error: the user allows health data only")
    }
}

/// The store `health_query` reads: HealthKit on iPhone, none on the Mac.
enum HealthStores {
    static var `default`: any HealthDataSource {
        #if os(iOS)
        HealthKitStore.shared
        #else
        UnavailableHealthStore()
        #endif
    }

    static func describe(_ error: Error) -> String {
        #if os(iOS)
        HealthKitStore.describe(error)
        #else
        error.localizedDescription
        #endif
    }
}

/// No Health data here (the Mac).
struct UnavailableHealthStore: HealthDataSource {
    var isAvailable: Bool { false }
    func needsAuthorization(for metrics: [HealthMetric]) async -> Bool { false }
    func requestAuthorization(for metrics: [HealthMetric]) async throws {}
    func units(for metrics: [HealthMetric]) async -> HealthUnits { .locale() }
    func statistics(_ metric: HealthMetric, in interval: DateInterval, bucket: HealthBucket, calendar: Calendar) async throws -> [HealthStat] { [] }
    func samples(_ metric: HealthMetric, in interval: DateInterval, limit: Int) async throws -> [HealthSample] { [] }
    func workouts(in interval: DateInterval, limit: Int) async throws -> [HealthWorkout] { [] }
}
