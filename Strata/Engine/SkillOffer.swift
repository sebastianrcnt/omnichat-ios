import Foundation

/// "Save as skill": a chip under a finished answer that took hard-won web work, the app's side of
/// `AppPrompt.skillOffer`. Tapping it sends `instruction` as a hidden turn; the model writes the skill with `save_skill`,
/// which asks for approval as usual. It costs a model turn only when tapped.
enum SkillOffer {
    /// Sent to the model as it is; never shown in the transcript.
    static let instruction = """
        Save what worked in this chat as a skill with save_skill, so a similar request goes faster next time. Write down \
        the steps, URLs, selectors and scripts that succeeded, and briefly what to avoid from the attempts that failed. \
        Keep it general enough for similar requests, not just this one. If a skill you loaded covers this, update it \
        (same name) instead of making a new one. Don't redo the task. After saving, reply in one short line.
        """
    /// A turn whose calls recovered from a failure needs at least this many web calls...
    static let minimumCallsAfterFailure = 3
    /// ...otherwise this many, at least one of them in the browser.
    static let minimumCalls = 6

    /// Whether a finished turn looks like hard-won work worth keeping:
    /// - the browser tools (and so `save_skill`) are offered, and the turn ended with an answer: not stopped, not failed;
    /// - it didn't call `save_skill` already;
    /// - a web call failed and a later one worked, or it made many web calls including the browser (pure search and
    ///   read is research, not a procedure to keep);
    /// - a skill it loaded didn't simply work (then the skill already covers it).
    static func isOffered(steps: [ToolStep], browserAvailable: Bool, finishedWithAnswer: Bool) -> Bool {
        guard browserAvailable, finishedWithAnswer else { return false }
        let calls = steps.flatMap(\.calls)
        guard !calls.contains(where: { $0.name == ToolNames.saveSkill }) else { return false }
        let web = calls.filter { ToolNames.usesWebPage($0.name) }
        let recovered = web.firstIndex(where: \.isError).map { failed in web[(failed + 1)...].contains { !$0.isError } } ?? false
        let loadedSkill = calls.contains { $0.name == ToolNames.loadSkill && !$0.isError }
        if loadedSkill && !recovered { return false }
        if recovered && web.count >= minimumCallsAfterFailure { return true }
        let browser = web.contains { [ToolNames.browserOpen, ToolNames.browserEval, ToolNames.runSkillScript, ToolNames.runPlugin].contains($0.name) }
        return browser && web.count >= minimumCalls
    }
}
