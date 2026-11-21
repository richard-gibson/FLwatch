import Foundation

/// A single, explicitly confirmed NFC pairing attempt. The transport owns
/// the tag session and must deliver each response to its original attempt.
struct Libre2Pairing {
    struct Sensor: Codable, Equatable {
        let uid: Data
        let patchInfo: Data
    }

    struct Credentials: Codable, Equatable {
        let sensor: Sensor
        let bluetoothAddress: Data
        let encryptedFRAM: Data
        let unlockCode: UInt32
        var unlockCounter: UInt16

        var isValid: Bool {
            sensor.uid.count == 8 && sensor.patchInfo.count == 6
                && Libre2Gen1.supportsPlus(patchInfo: sensor.patchInfo)
                && bluetoothAddress.count == 6 && encryptedFRAM.count == 344
        }
    }

    enum Request: Equatable {
        case readPatchInfo
        case readFRAM
        case enableStreaming(parameters: Data)
    }

    enum PairingError: Error, Equatable {
        case unexpectedResponse
        case malformedPatchInfo
        case unsupportedSensor
        case malformedFRAM
        case malformedBluetoothAddress
    }

    private enum State {
        case readingPatchInfo
        case awaitingConfirmation(Sensor)
        case readingFRAM(Sensor)
        case enabling(Sensor, encryptedFRAM: Data, code: UInt32)
        case complete
        case cancelled
    }

    private var state: State = .readingPatchInfo
    let firstRequest: Request = .readPatchInfo

    mutating func receivePatchInfo(uid: Data, patchInfo: Data) throws {
        guard case .readingPatchInfo = state else { throw PairingError.unexpectedResponse }
        guard uid.count == 8, patchInfo.count == 6 else {
            cancel()
            throw PairingError.malformedPatchInfo
        }
        guard Libre2Gen1.supportsPlus(patchInfo: patchInfo) else {
            cancel()
            throw PairingError.unsupportedSensor
        }
        state = .awaitingConfirmation(Sensor(uid: uid, patchInfo: patchInfo))
    }

    mutating func confirmStreaming() throws -> Request {
        guard case .awaitingConfirmation(let sensor) = state else {
            throw PairingError.unexpectedResponse
        }
        state = .readingFRAM(sensor)
        return .readFRAM
    }

    mutating func receiveFRAM(_ data: Data, unlockCode: UInt32) throws -> Request {
        guard case .readingFRAM(let sensor) = state else { throw PairingError.unexpectedResponse }
        guard data.count == 344 else {
            cancel()
            throw PairingError.malformedFRAM
        }
        let parameters = Libre2Gen1.enableStreamingParameters(
            uid: Array(sensor.uid), patchInfo: Array(sensor.patchInfo), code: unlockCode
        )
        state = .enabling(sensor, encryptedFRAM: data, code: unlockCode)
        return .enableStreaming(parameters: parameters)
    }

    mutating func receiveStreamingResponse(_ response: Data) throws -> Credentials {
        guard case .enabling(let sensor, let fram, let code) = state else {
            throw PairingError.unexpectedResponse
        }
        guard response.count == 6 else {
            cancel()
            throw PairingError.malformedBluetoothAddress
        }
        state = .complete
        return Credentials(
            sensor: sensor, bluetoothAddress: Data(response.reversed()), encryptedFRAM: fram,
            unlockCode: code, unlockCounter: 0
        )
    }

    mutating func cancel() {
        state = .cancelled
    }
}
