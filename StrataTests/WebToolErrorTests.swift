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
