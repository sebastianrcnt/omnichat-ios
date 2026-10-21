import Testing
import Foundation
@testable import Strata

struct ModelSelectionTests {
    private func strata(_ models: [String]) -> Connection {
        Connection(id: Connection.testID, name: "Strata", baseURL: Connection.testBaseURL, models: models.map { ModelInfo(id: $0) })
    }

    @Test func noConnectionIsFavoredWhenNothingSelected() {
        let other = Connection(name: "Local", baseURL: "http://localhost/v1", models: [ModelInfo(id: "local-1")])
        let choice = ModelSelection.resolve(connections: [other, strata(["a", "b"])], preferredConnectionID: nil, preferredModelID: nil)
        #expect(choice == .init(connectionID: other.id, modelID: "local-1"))
    }

    @Test func aStaleModelFallsBackWithinThePreferredConnection() {
        let other = Connection(name: "Local", baseURL: "http://localhost/v1", models: [ModelInfo(id: "local-1")])
        let choice = ModelSelection.resolve(connections: [other, strata(["a", "b"])], preferredConnectionID: Connection.testID,
                                            preferredModelID: "gone")
        #expect(choice == .init(connectionID: Connection.testID, modelID: "a"))
    }

    @Test func keepsValidPreference() {
        let choice = ModelSelection.resolve(connections: [strata(["a", "b"])], preferredConnectionID: Connection.testID, preferredModelID: "b")
        #expect(choice?.modelID == "b")
    }

    @Test func replacesStalePreference() {
        let choice = ModelSelection.resolve(connections: [strata(["a"])], preferredConnectionID: Connection.testID, preferredModelID: "gone")
        #expect(choice?.modelID == "a")
    }

    @Test func fallsBackToAnyConnectionAndNilWhenEmpty() {
        let other = Connection(name: "Local", baseURL: "http://localhost/v1", models: [ModelInfo(id: "local-1")])
        let emptyStrata = strata([])
        #expect(ModelSelection.resolve(connections: [emptyStrata, other], preferredConnectionID: nil, preferredModelID: nil)?.modelID == "local-1")
        #expect(ModelSelection.resolve(connections: [emptyStrata], preferredConnectionID: nil, preferredModelID: nil) == nil)
    }
}

struct ContextRingTests {
    @Test func arcIsVisibleForAnyUsage() {
        #expect(ContextRing.arc(for: 0) == 0)
        #expect(ContextRing.arc(for: 0.001) == ContextRing.minimumVisibleArc)
        #expect(ContextRing.arc(for: 0.5) == 0.5)
        #expect(ContextRing.arc(for: 3) == 1)
    }

    @Test func apiErrorsThatNeedSettings() {
        #expect(APIError.missingModel.needsSettings)
        #expect(APIError.missingAPIKey(connection: "Strata").needsSettings)
        #expect(!APIError.http(status: 500, message: "x").needsSettings)
    }
}
