import Foundation

/// Drives one BLE connection at a time. A transport tags its callbacks
/// with the attempt returned by startConnection to ignore stale events.
struct Libre2Stream {
    enum Request: Equatable {
        case discover(address: Data)
        case subscribe
        case writeUnlock(Data)
    }

    enum StreamError: Error, Equatable {
        case connectionInProgress
        case unlockCounterExhausted
    }

    private enum State {
        case disconnected
        case discovering(UUID)
        case subscribing(UUID)
        case unlocking(UUID)
        case streaming(UUID)
    }

    private var state: State = .disconnected
    private var credentials: Libre2Pairing.Credentials
    private var assembler = Libre2Gen1.FrameAssembler()
    private var recentFrames: [Libre2Gen1.Frame] = []

    init(credentials: Libre2Pairing.Credentials) {
        self.credentials = credentials
    }

    mutating func startConnection() throws -> (attempt: UUID, request: Request) {
        guard case .disconnected = state else { throw StreamError.connectionInProgress }
        let attempt = UUID()
        state = .discovering(attempt)
        return (attempt, .discover(address: credentials.bluetoothAddress))
    }

    mutating func didDiscover(attempt: UUID) -> Request? {
        guard case .discovering(attempt) = state else { return nil }
        state = .subscribing(attempt)
        return .subscribe
    }

    mutating func didSubscribe(
        attempt: UUID, saveCounter: (UInt16) throws -> Void
    ) throws -> Request? {
        guard case .subscribing(attempt) = state else { return nil }
        guard credentials.unlockCounter < .max else { throw StreamError.unlockCounterExhausted }
        let next = credentials.unlockCounter + 1
        // Persist before handing the payload to the transport. A write that
        // reaches the sensor can consume the counter even if its callback is lost.
        try saveCounter(next)
        credentials.unlockCounter = next
        state = .unlocking(attempt)
        return .writeUnlock(Libre2Gen1.streamingUnlock(
            uid: Array(credentials.sensor.uid), patchInfo: Array(credentials.sensor.patchInfo),
            code: credentials.unlockCode, counter: next
        ))
    }

    mutating func didWriteUnlock(attempt: UUID) {
        guard case .unlocking(attempt) = state else { return }
        state = .streaming(attempt)
    }

    mutating func receive(_ fragment: Data, attempt: UUID) throws -> Libre2Gen1.Frame? {
        guard case .streaming(attempt) = state,
              let bytes = try assembler.append(fragment) else { return nil }
        let frame = try Libre2Gen1.decode(bytes, sensorUID: credentials.sensor.uid)
        guard !recentFrames.contains(frame) else { return nil }
        recentFrames.append(frame)
        if recentFrames.count > 16 { recentFrames.removeFirst() }
        return frame
    }

    mutating func partialFrameTimedOut(attempt: UUID) {
        guard case .streaming(attempt) = state else { return }
        assembler.reset()
    }

    mutating func didDisconnect(attempt: UUID) {
        switch state {
        case .discovering(attempt), .subscribing(attempt), .unlocking(attempt), .streaming(attempt):
            assembler.reset()
            state = .disconnected
        default:
            break
        }
    }
}
