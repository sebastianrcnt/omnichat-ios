import Foundation
import Testing
@testable import Strata

/// When a failed reply says the background stopped it (`BackgroundInterruption`), and when it keeps its own error.
struct BackgroundInterruptionTests {
    private func classified(_ error: Error, background: Bool = true, resumable: Bool = false) -> Bool {
        BackgroundInterruption.classify(error, wentToBackground: background, resumable: resumable) is BackgroundInterruption
    }

    @Test func droppedConnectionsAfterGoingToTheBackgroundSaySo() {
        #expect(classified(URLError(.networkConnectionLost)))
        #expect(classified(URLError(.timedOut)))
        #expect(classified(URLError(.notConnectedToInternet)))
        #expect(classified(APIError.transport(ChatClient.cutOffMessage)))
        #expect(classified(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNABORTED))))
        #expect(classified(NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost)))
    }

    @Test func serverErrorsKeepTheirOwnMessage() {
        #expect(!classified(APIError.http(status: 500, message: "boom")))
        #expect(!classified(APIError.server("overloaded")))
        #expect(!classified(APIError.rejectedAPIKey(connection: "x")))
        #expect(!classified(APIError.chatGPTUsageLimit))
        #expect(!classified(URLError(.badServerResponse)))
        #expect(!classified(URLError(.cancelled)))
        #expect(!classified(CocoaError(.coderReadCorrupt)))
    }

    @Test func onlyWhenTheAppWentToTheBackground() {
        #expect(!classified(URLError(.networkConnectionLost), background: false))
    }

    @Test func aResumableConnectionKeepsItsOwnPath() {
        #expect(!classified(URLError(.networkConnectionLost), resumable: true))
        #expect(!classified(StreamOutage(minutes: 10), resumable: true))
    }

    @Test func otherErrorsPassThroughUnchanged() {
        let error = BackgroundInterruption.classify(APIError.http(status: 429, message: "slow down"),
                                                    wentToBackground: true, resumable: false)
        #expect(error as? APIError == .http(status: 429, message: "slow down"))
    }

    @Test func theNoticeSaysWhatHappened() {
        #expect(BackgroundInterruption().localizedDescription == "The reply stopped while OmniChat was in the background. Try again.")
    }
}
