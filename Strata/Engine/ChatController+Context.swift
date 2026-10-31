import Foundation
import SwiftUI
import SwiftData
import Observation

/// What a request sends (history, tools, the context window) and compaction.
extension ChatController {
    // MARK: Compaction

    /// The messages to send for `path`: the conversation's latest compaction on it, then what follows its anchor.
    /// `freeze` is false for display-only estimates, which must not pin the chat's preferences or tools before it sends.
    func apiHistory(path: [Message], conversation: Conversation, endpoint: Endpoint, freeze: Bool = true) -> [APIMessage] {
        let tools = endpoint.model.supportsTools
        // A model without tools is offered no tool group, only the views (a prompt section, no tools).
        let offered = tools ? offeredTools(conversation, freeze: freeze) : offeredTools(conversation, freeze: freeze).intersection([.views])
        // Like the skill list: a chat keeps the plugin section it first had with web tools on.
        // A plugin a built-in package replaced (Wikipedia) is left out when the chat has that package: it offers it.
        let currentPlugins = {
            let replaced = self.packages.replacedPlugins(by: self.chatPackages(conversation)?.ids ?? [])
            return PluginRegistry.bundled.promptSection(enabled: AppSettings.currentEnabledPlugins.subtracting(replaced))
        }
        let plugins = !offered.contains(.web) ? ""
            : freeze ? conversation.frozenPluginSection(current: currentPlugins()) : conversation.pluginSectionSnapshot ?? currentPlugins()
        // A chat keeps the skill list it first had with the browser on, like its preferences.
        let skillIndex = !offered.contains(.browser) ? ""
            : freeze ? conversation.frozenSkillIndex(current: skills.index) : conversation.skillIndexSnapshot ?? skills.index
        let base = [AppPrompt.text(tools: tools, python: offered.contains(.python), browser: offered.contains(.browser),
                                   skills: offered.contains(.browser), video: offered.contains(.video), ssh: offered.contains(.ssh),
                                   health: offered.contains(.health) && ToolGroup.health.isSupported, views: offered.contains(.views)),
                    skillIndex,
                    tools ? chatPackages(conversation)?.promptSections ?? "" : "",
                    AppPrompt.preferences(freeze ? conversation.frozenPreferences(current: settings.userPreferences)
                                                  : conversation.preferencesSnapshot ?? settings.userPreferences)]
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        let system = ConversationDate.systemPrompt(base: base, day: conversation.systemDay, plugins: plugins)
        // An Anthropic model gets its own thinking back on the steps of earlier turns (`StepThinking`).
        let thinkingModel = endpoint.kind == .anthropic ? endpoint.model.id : nil
        if let compacted = conversation.compactedHistory(path: path) {
            return MessageAssembler.apiMessages(from: compacted.rest, systemPrompt: system, replacing: compacted.replacement,
                                                readsImages: endpoint.model.supportsImages, thinkingModel: thinkingModel)
        }
        let history = path.filter { $0.role == .user || !$0.text.isEmpty || !$0.steps.isEmpty }.map(\.historyMessage)
        return MessageAssembler.apiMessages(from: history, systemPrompt: system, readsImages: endpoint.model.supportsImages,
                                            thinkingModel: thinkingModel)
    }

    /// Why a request from the chat may not go to `endpoint` (`HealthPrivacy.blockedRequest`); nil when it may.
    func healthBlock(_ conversation: Conversation, _ endpoint: Endpoint?) -> APIError? {
        HealthPrivacy.blockedRequest(conversation, to: endpoint.map { ToolDestination($0) }, localOnly: healthLocalOnly())
    }

    /// The tools the chat's requests send (see `ToolDefinition.available`).
    func requestTools(_ endpoint: Endpoint, conversation: Conversation) -> [ToolDefinition] {
        let offered = offeredTools(conversation, freeze: false)
        return ToolDefinition.available(groups: offered, images: endpoint.model.supportsImages)
            + (chatPackages(conversation)?.requestTools(browserOffered: offered.contains(.browser)) ?? [])
    }

    /// The chat's effort as one the model offers: Off picked on a model that always thinks is sent as its lowest level.
    func requestEffort(_ conversation: Conversation, endpoint: Endpoint) -> Effort {
        let style = connections.connection(endpoint.connectionID)?.effortStyle ?? .tokenCaps
        return conversation.effort.resolved(in: endpoint.model.effortLevels(style))
    }

    /// The window, the room for an answer and the context size before this turn's own message.
    func contextWindow(for endpoint: Endpoint) -> Int {
        var window = endpoint.model.effectiveContextLength(default: settings.defaultContextLength)
        #if DEBUG
        if let n = Int(DebugHooks.value("StrataContextWindow") ?? ""), n > 0 { window = n }
        #endif
        return window
    }

    func compactionSettings(conversation: Conversation, endpoint: Endpoint, messages: [APIMessage], path: [Message]) -> CompactionSettings {
        let window = contextWindow(for: endpoint)
        // The last reported usage belongs to the request that ended just before this turn's user message, when it was
        // made on this branch; otherwise everything is an estimate.
        let history = messages.last?.role == "user" ? Array(messages.dropLast()) : messages
        var meter = ContextMeter.estimate(history)
        if let usage = conversation.lastUsage, let id = conversation.lastUsageMessageID,
           path.dropLast().last?.id == id {
            meter = ContextMeter(usage: usage)
        }
        return CompactionSettings(window: window, maxOutput: endpoint.model.maxOutputTokens, meter: meter)
    }

    /// Saves a compaction, replacing one made at the same point (a turn restored after the notes were written), and
    /// moves the context ring to the size after it.
    func storeCompaction(_ outcome: CompactionOutcome, conversation: Conversation, anchor: UUID?, anchorSteps: Int,
                         automatic: Bool, context: ModelContext) {
        conversation.apply(Usage(promptTokens: outcome.tokensAfter, completionTokens: 0))
        guard let anchor else { return }
        for old in conversation.compactions where old.anchorMessageID == anchor && old.anchorSteps == anchorSteps {
            context.delete(old)
        }
        guard let record = try? CompactionRecord(anchorMessageID: anchor, anchorSteps: anchorSteps, notes: outcome.notes,
                                                 replacement: outcome.replacement, tokensBefore: outcome.tokensBefore,
                                                 tokensAfter: outcome.tokensAfter, isAutomatic: automatic) else { return }
        context.insert(record)
        record.conversation = conversation
        try? context.save()
    }

    /// The Context sheet's split of `total` tokens by category, estimated from what the next request would send (the
    /// same history and tools as a turn). Display only: nothing is sent or stored. Nil when the chat has no endpoint.
    func contextSplit(conversation: Conversation, total: Int) -> [Int]? {
        guard let endpoint = connections.endpoint(connectionID: conversation.connectionID, modelID: conversation.modelID,
                                                  sessionID: conversation.id.uuidString)
        else { return nil }
        let messages = apiHistory(path: conversation.activePath, conversation: conversation, endpoint: endpoint, freeze: false)
        return ContextEstimator.split(messages: messages, tools: endpoint.model.supportsTools ? requestTools(endpoint, conversation: conversation) : nil,
                                      total: total)
    }
}
