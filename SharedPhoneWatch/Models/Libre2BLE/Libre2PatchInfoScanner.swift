#if os(iOS)
import Combine
import CoreNFC
import Foundation

@MainActor
final class Libre2PatchInfoScanner: NSObject, ObservableObject, @preconcurrency NFCTagReaderSessionDelegate {
    enum State: Equatable {
        case idle
        case scanning
        case read(patchInfo: Data)
        case paired
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var session: NFCTagReaderSession?
    private var readTask: Task<Void, Never>?
    private var inspectedSensor: Libre2Pairing.Sensor?
    private var confirmedSensor: Libre2Pairing.Sensor?

    var canPair: Bool {
        guard case .read = state, let inspectedSensor else { return false }
        return inspectedSensor.uid.count == 8 && inspectedSensor.patchInfo.count == 6
            && Libre2Gen1.supportsPlus(patchInfo: inspectedSensor.patchInfo)
    }

    func scan() {
        begin(confirmedSensor: nil)
    }

    func pairInspectedSensor() {
        guard canPair else { return }
        begin(confirmedSensor: inspectedSensor)
    }

    private func begin(confirmedSensor: Libre2Pairing.Sensor?) {
        guard session == nil else { return }
        guard NFCTagReaderSession.readingAvailable,
              let session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: .main) else {
            state = .failed(String(localized: "This iPhone can't scan NFC tags."))
            return
        }

        inspectedSensor = nil
        self.confirmedSensor = confirmedSensor
        self.session = session
        state = .scanning
        session.alertMessage = String(localized: "Hold the top of your iPhone against the Libre 2 Plus sensor.")
        session.begin()
    }

    func cancel() {
        let session = self.session
        clearSession()
        inspectedSensor = nil
        state = .idle
        session?.invalidate()
    }

    func tagReaderSessionDidBecomeActive(_ session: NFCTagReaderSession) {}

    func tagReaderSession(_ session: NFCTagReaderSession, didInvalidateWithError error: Error) {
        guard self.session === session else { return }
        clearSession()
        if (error as? NFCReaderError)?.code == .readerSessionInvalidationErrorUserCanceled {
            state = .idle
        } else {
            state = .failed(Self.readError)
        }
    }

    func tagReaderSession(_ session: NFCTagReaderSession, didDetect tags: [NFCTag]) {
        guard self.session === session, readTask == nil else { return }
        guard tags.count == 1, case .iso15693(let tag) = tags[0], tag.icManufacturerCode == 0x07 else {
            fail(session)
            return
        }

        let detectedTag = tags[0]
        readTask = Task { [weak self] in
            do {
                try await session.connect(to: detectedTag)
                try Task.checkCancellation()
                // An empty request is read-only.
                let patchInfo = try await Self.command(Data(), tag: tag)
                guard let self, self.session === session else { return }
                guard patchInfo.count >= 4 else {
                    self.fail(session)
                    return
                }
                let sensor = Libre2Pairing.Sensor(uid: Data(tag.identifier.reversed()), patchInfo: patchInfo)
                if let confirmedSensor = self.confirmedSensor {
                    guard sensor == confirmedSensor else {
                        self.fail(session, message: String(localized: "Scan the same Libre 2 Plus sensor you checked."))
                        return
                    }
                    try await self.enableStreaming(on: tag, sensor: sensor, session: session)
                } else {
                    self.inspectedSensor = sensor
                    self.finish(session, state: .read(patchInfo: patchInfo),
                                message: String(localized: "Sensor information read."))
                }
            } catch {
                guard let self, self.session === session else { return }
                self.fail(session)
            }
        }
    }

    private func enableStreaming(
        on tag: any NFCISO15693Tag, sensor: Libre2Pairing.Sensor, session: NFCTagReaderSession
    ) async throws {
        var pairing = Libre2Pairing()
        try pairing.receivePatchInfo(uid: sensor.uid, patchInfo: sensor.patchInfo)
        _ = try pairing.confirmStreaming()
        let fram = try await Self.readFRAM(tag)
        try Task.checkCancellation()
        guard Libre2Gen1.isReadyToStream(encryptedFRAM: fram, sensorUID: sensor.uid, patchInfo: sensor.patchInfo) else {
            fail(session, message: String(localized: "Use a Libre 2 Plus sensor that has finished warming up."))
            return
        }

        let request = try pairing.receiveFRAM(fram, unlockCode: UInt32.random(in: 1...UInt32.max - UInt32(UInt16.max)))
        guard case .enableStreaming(let parameters) = request else { return }
        let response = try await Self.command(parameters, tag: tag)
        guard self.session === session else { return }
        let credentials = try pairing.receiveStreamingResponse(response)
        do {
            try Libre2CredentialsStore.save(credentials)
        } catch {
            fail(session, message: String(localized: "Streaming was enabled, but pairing could not be saved. Pair the sensor again."))
            return
        }
        finish(session, state: .paired, message: String(localized: "Libre 2 Plus pairing saved."))
    }

    private static func command(_ parameters: Data, tag: any NFCISO15693Tag) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            tag.customCommand(
                requestFlags: .highDataRate, customCommandCode: 0xA1, customRequestParameters: parameters,
                resultHandler: { continuation.resume(with: $0) }
            )
        }
    }

    private static func readFRAM(_ tag: any NFCISO15693Tag) async throws -> Data {
        var result = Data()
        for firstBlock in stride(from: 0, to: 43, by: 3) {
            try Task.checkCancellation()
            let count = min(3, 43 - firstBlock)
            let blocks: [Data] = try await withCheckedThrowingContinuation { continuation in
                tag.readMultipleBlocks(
                    requestFlags: [.address, .highDataRate],
                    blockRange: NSRange(location: firstBlock, length: count),
                    resultHandler: { continuation.resume(with: $0) }
                )
            }
            guard blocks.count == count, blocks.allSatisfy({ $0.count == 8 }) else {
                throw Libre2Pairing.PairingError.malformedFRAM
            }
            for block in blocks { result.append(block) }
        }
        return result
    }

    private static var readError: String {
        String(localized: "Couldn't read the sensor. Hold the top of your phone against the sensor and hold still.")
    }

    private func fail(_ session: NFCTagReaderSession, message: String? = nil) {
        let message = message ?? Self.readError
        clearSession()
        state = .failed(message)
        session.invalidate(errorMessage: message)
    }

    private func finish(_ session: NFCTagReaderSession, state: State, message: String) {
        clearSession()
        self.state = state
        session.alertMessage = message
        session.invalidate()
    }

    private func clearSession() {
        session = nil
        confirmedSensor = nil
        readTask?.cancel()
        readTask = nil
    }
}
#endif
