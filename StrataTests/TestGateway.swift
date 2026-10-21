import Foundation
@testable import Strata

/// The connection engine tests talk to (through stub streamers, never the network). It stands in for the connection
/// that used to be built into the app: same name, resumable replies on, at an address that is not real.
extension Connection {
    static let testID = UUID(uuidString: "7E57C0DE-0000-4000-8000-000000000001")!
    static let testBaseURL = "https://gateway.invalid/v1"

    static func testGateway(models: [ModelInfo] = []) -> Connection {
        Connection(id: testID, name: "Strata", baseURL: testBaseURL, models: models, supportsResumable: true)
    }
}

extension ConnectionStore {
    /// The test gateway, added first if the store doesn't have it yet.
    @MainActor
    @discardableResult
    func testGateway() -> Connection {
        if let existing = connection(Connection.testID) { return existing }
        let gateway = Connection.testGateway()
        upsert(gateway)
        return gateway
    }
}
