import Foundation

/// What OpenAI's Sign in with ChatGPT UI guidelines (developers.openai.com/siwc/ui-ux-guidelines) ask the app to show
/// around plan usage: a welcome the first time a sign-in allows it, "Using ChatGPT plan" with a "Manage usage" link near
/// the model selector while a chat's model is on a ChatGPT connection, and "Manage usage" as the first action of a
/// usage-limit error. Every link goes to `ChatGPTOAuth.usageURL`.
enum ChatGPTPlanUsage {
    /// Per device (UserDefaults is not synced): set once the welcome was shown.
    static let welcomeShownKey = "chatGPT.planWelcomeShown"

    /// Whether this sign-in shows the welcome, marking it shown when it does. True only for the first sign-in on this
    /// device that allowed plan usage: never on later sign-ins, of this connection or another. A sign-in that didn't allow
    /// it leaves the welcome for the first one that does.
    static func claimWelcome(planAllowed: Bool, defaults: UserDefaults = .standard) -> Bool {
        guard planAllowed, !defaults.bool(forKey: welcomeShownKey) else { return false }
        defaults.set(true, forKey: welcomeShownKey)
        return true
    }
}
