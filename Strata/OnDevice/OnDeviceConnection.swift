import Foundation

extension Connection {
    /// The on-device connection: one model, Apple's, with what this device's model can do.
    static func appleOnDevice(name: String = OnDevice.connectionName,
                              model: any OnDeviceLanguageModel = OnDevice.system) -> Connection {
        var c = Connection(kind: .appleOnDevice, name: name, baseURL: OnDevice.baseURL.absoluteString, supportsResumable: false)
        c.models = [OnDevice.modelInfo(model)]
        return c
    }
}

extension OnDevice {
    /// The model as the connection lists it: the window and image input as the system reports them now, no reasoning
    /// effort. An alias, "Show in picker" and the tools switch stay as the user set them.
    static func modelInfo(_ model: any OnDeviceLanguageModel, keeping existing: ModelInfo? = nil) -> ModelInfo {
        var info = existing ?? ModelInfo(id: modelID, supportsTools: true)
        info.id = modelID
        info.fetchedDisplayName = modelName
        info.fetchedContextLength = model.contextSize
        info.supportsImages = model.readsImages
        info.supportsImagesUserSet = false
        info.supportsEffort = false
        info.supportsEffortUserSet = false
        info.isManual = false
        return info
    }

    /// An endpoint for the on-device model on `connection`.
    static func endpoint(_ connection: Connection, model: any OnDeviceLanguageModel = OnDevice.system) -> Endpoint {
        let stored = connection.models.first { $0.id == modelID }
        return Endpoint(connectionID: connection.id, connectionName: connection.name, baseURL: baseURL, apiKey: nil,
                        headers: [:], model: modelInfo(model, keeping: stored), supportsResumable: false, kind: .appleOnDevice)
    }

    /// Where chat titles are asked when "Name chats on device" is on: the on-device connection, or one made for the
    /// purpose when there is none. Nil when the setting is off or the model can't run now (the chat's own model names
    /// it then, as without the setting).
    static func titleEndpoint(enabled: Bool, connections: [Connection],
                              model: any OnDeviceLanguageModel = OnDevice.system) -> Endpoint? {
        guard enabled, model.availability.isAvailable else { return nil }
        let connection = connections.first(where: \.isAppleOnDevice)
            ?? Connection(id: titleConnectionID, kind: .appleOnDevice, name: connectionName, baseURL: baseURL.absoluteString)
        return endpoint(connection, model: model)
    }

    /// Whether to offer the on-device model as a new connection (first run, "Add a connection"): the device supports
    /// it (even if Apple Intelligence is off or the model is still downloading: the editor says what to do) and there
    /// isn't one already.
    static func offersConnection(availability: OnDeviceAvailability, connections: [Connection]) -> Bool {
        availability.isSupported && !connections.contains(where: \.isAppleOnDevice)
    }
}

extension ConnectionStore {
    /// The on-device connection, if one was added. There is at most one: adding it again opens the one there is.
    var onDeviceConnection: Connection? { connections.first(where: \.isAppleOnDevice) }

    /// Adds the on-device connection, or returns the existing one.
    @discardableResult
    func addOnDeviceConnection(model: any OnDeviceLanguageModel = OnDevice.system) -> Connection {
        if let existing = onDeviceConnection { return existing }
        let new = Connection.appleOnDevice(name: String(localized: "Apple Intelligence"), model: model)
        upsert(new)
        return new
    }

    /// Updates what the on-device model can do (after a system update it may read images or have a larger window).
    /// Nothing is fetched; nothing is saved when nothing changed.
    func refreshOnDeviceModels(model: any OnDeviceLanguageModel = OnDevice.system) {
        for c in connections where c.isAppleOnDevice {
            var updated = c
            updated.models = [OnDevice.modelInfo(model, keeping: c.models.first { $0.id == OnDevice.modelID })]
            if updated != c { upsert(updated) }
        }
    }
}
