import Foundation
import Testing
@testable import Strata

struct WebToolErrorTests {
    @Test func certificateFailuresAreReportedAsInsecure() {
        for code in [NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                     NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorSecureConnectionFailed] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            #expect(WebToolError.loadFailure(error) == .insecure)
        }
        #expect(WebToolError.insecure.errorDescription?.contains("use another source") == true)
    }

    @Test func otherFailuresKeepTheirMessage() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                            userInfo: [NSLocalizedDescriptionKey: "host not found"])
        #expect(WebToolError.loadFailure(error) == .navigation("host not found"))
    }
}

struct FetchTimeoutTests {
    @Test func timeoutMessageSaysHowLongAndWhichLimit() {
        let m = WebToolError.timeoutMessage(after: .milliseconds(15_240), limit: .seconds(15), what: "loading the page")
        #expect(m.hasPrefix("Timed out after 15.2 s: loading the page has a 15 s limit."))
        #expect(FetchFailure(errorText: "Error: " + m) == .timedOut)
    }

    @Test func patiencePresets() {
        #expect(FetchPatience.standard.timeouts == .standard)
        #expect(FetchPatience.fast.timeouts.overall == .seconds(15))
        #expect(FetchPatience.patient.timeouts.load == .seconds(30))
    }

    @Test func failureReasonsFromErrorText() {
        #expect(FetchFailure(errorText: "Error: " + (WebToolError.insecure.errorDescription ?? "")) == .certificate)
        #expect(FetchFailure(errorText: "Error: Page script failed: the page has no readable text.") == .noText)
        #expect(FetchFailure(errorText: "Error: HTTP 403 Forbidden") == .blocked)
        #expect(FetchFailure(errorText: "Error: The page failed to load: something") == .failed)
    }
}
