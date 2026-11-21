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
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    private var session: NFCTagReaderSession?
    private var readTask: Task<Void, Never>?

    func scan() {
        guard session == nil else { return }
        guard NFCTagReaderSession.readingAvailable,
              let session = NFCTagReaderSession(pollingOption: .iso15693, delegate: self, queue: .main) else {
            state = .failed(String(localized: "This iPhone can't scan NFC tags."))
            return
        }

        self.session = session
        state = .scanning
        session.alertMessage = String(localized: "Hold the top of your iPhone against the Libre 2 Plus sensor.")
        session.begin()
    }

    func cancel() {
        let session = self.session
        clearSession()
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
                // The empty request reads patch info. Streaming and activation
                // use separate subcommands with nonempty request parameters.
                let patchInfo = try await withCheckedThrowingContinuation { continuation in
                    tag.customCommand(
                        requestFlags: .highDataRate,
                        customCommandCode: 0xA1,
                        customRequestParameters: Data(),
                        resultHandler: { continuation.resume(with: $0) }
                    )
                }
                guard let self, self.session === session else { return }
                guard patchInfo.count >= 4 else {
                    self.fail(session)
                    return
                }
                self.clearSession()
                self.state = .read(patchInfo: patchInfo)
                session.alertMessage = String(localized: "Sensor information read.")
                session.invalidate()
            } catch {
                guard let self, self.session === session else { return }
                self.fail(session)
            }
        }
    }

    private static var readError: String {
        String(localized: "Couldn't read the sensor. Hold the top of your phone against the sensor and hold still.")
    }

    private func fail(_ session: NFCTagReaderSession) {
        clearSession()
        state = .failed(Self.readError)
        session.invalidate(errorMessage: Self.readError)
    }

    private func clearSession() {
        session = nil
        readTask?.cancel()
        readTask = nil
    }
}
#endif
