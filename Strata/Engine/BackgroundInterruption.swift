import Foundation

/// A reply that stopped because OmniChat left the screen: iOS cuts an app's network soon after it goes to the
/// background (and at once when the background lease ends), and only a connection with Resumable replies can pick the
/// stream up again (`StreamRecovery`). Without it the reply ends, and this says why instead of a bare "The network
/// connection was lost." that reads like the server's fault. Pure, so the rules are tested without a suspended app.
struct BackgroundInterruption: LocalizedError, Equatable {
    var errorDescription: String? {
        String(localized: "The reply stopped while OmniChat was in the background. Try again.")
    }

    /// The error a reply ends with: this notice in place of a dropped connection when the app went to the background
    /// during the reply and the connection can't resume it; any other error (the server's own, a resumable outage, a
    /// failure while the app stayed in front) as it was.
    static func classify(_ error: Error, wentToBackground: Bool, resumable: Bool) -> Error {
        guard wentToBackground, !resumable, isConnectionLoss(error) else { return error }
        return BackgroundInterruption()
    }

    /// The connection broke or couldn't be made, as opposed to the server answering with an error.
    static func isConnectionLoss(_ error: Error) -> Bool {
        if let error = error as? URLError { return lostCodes.contains(error.code) }
        if case .transport? = error as? APIError { return true } // the stream ended before the reply did
        let ns = error as NSError
        if ns.domain == NSPOSIXErrorDomain { return lostPOSIX.contains(Int32(ns.code)) }
        return false
    }

    private static let lostCodes: Set<URLError.Code> = [
        .networkConnectionLost, .timedOut, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .secureConnectionFailed, .backgroundSessionWasDisconnected, .dataNotAllowed,
        .internationalRoamingOff, .callIsActive, .cannotLoadFromNetwork,
    ]
    private static let lostPOSIX: Set<Int32> = [ECONNABORTED, ECONNRESET, ENOTCONN, ETIMEDOUT, EPIPE, ENETDOWN, ENETRESET]
}
