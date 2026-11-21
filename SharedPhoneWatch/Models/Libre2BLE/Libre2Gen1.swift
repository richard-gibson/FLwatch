import Foundation

// BLE decoding adapted from LoopKit/LibreTransmitter's PreLibre2.swift at
// 41105123c3c4fb5c55ce89a38630cea2f8f7a17a. See LibreTransmitter-LICENSE.txt.
enum Libre2Gen1 {
    static let frameLength = 46

    enum DecodeError: Error, Equatable {
        case invalidSensorUID
        case invalidFrameLength
        case invalidChecksum
    }

    struct Frame: Equatable {
        let wearMinutes: Int
        let trend: [Sample]
        let history: [Sample]
    }

    struct Sample: Equatable {
        let sensorMinute: Int
        let rawGlucose: Int
        let rawTemperature: Int
        let rawTemperatureAdjustment: Int
    }

    /// Recognizes the supported EU Plus signatures. A successful match must
    /// still be followed by the NFC and BLE compatibility checks on hardware.
    static func supportsPlus(patchInfo: Data) -> Bool {
        let prefix = Array(patchInfo.prefix(4))
        guard prefix.count == 4, prefix[3] == 0x01 else { return false }
        return (prefix[0] == 0xC6 && prefix[2] == 0x31)
            || prefix == [0x7F, 0x0E, 0x31, 0x01]
    }

    /// Consumes notification fragments from one connection in arrival order.
    /// Reset on disconnect or when a partial frame times out.
    struct FrameAssembler {
        private var pending = Data()

        mutating func append(_ fragment: Data) throws -> Data? {
            guard fragment.count <= frameLength - pending.count else {
                reset()
                throw DecodeError.invalidFrameLength
            }
            pending.append(fragment)
            guard pending.count == frameLength else { return nil }
            let frame = pending
            reset()
            return frame
        }

        mutating func reset() {
            pending.removeAll(keepingCapacity: true)
        }
    }

    /// The UID is the eight NFC identifier bytes in Libre wire order.
    /// Dates can be derived later from a stable per-sensor start time.
    static func decode(_ frame: Data, sensorUID: Data) throws -> Frame {
        guard sensorUID.count == 8 else { throw DecodeError.invalidSensorUID }
        guard frame.count == frameLength else { throw DecodeError.invalidFrameLength }

        let uid = Array(sensorUID)
        let encrypted = Array(frame)
        let seed = keyBlock(uid: uid, x: 0x1B, y: 0x1B6A)
        let x = ((seed[0] ^ 0x4163) ^ (seed[1] ^ 0x4344)) | 0x63
        let y = word(encrypted, at: 0) ^ 0x63

        var key = keyBlock(uid: uid, x: x, y: y)
        var clear = [UInt8]()
        for (index, byte) in encrypted.dropFirst(2).enumerated() {
            if index > 0, index.isMultiple(of: 8) {
                key = transform(key)
            }
            let keyByte = UInt8(truncatingIfNeeded: key[(index % 8) / 2] >> (8 * (index % 2)))
            clear.append(byte ^ keyByte)
        }

        guard checksum(clear.prefix(42)) == word(clear, at: 42) else {
            throw DecodeError.invalidChecksum
        }

        let wearMinutes = Int(word(clear, at: 40))
        let trendOffsets = [0, 2, 4, 6, 7, 12, 15]
        // The most recent history slot reports with a two-minute delay.
        let historyMinute = wearMinutes >= 2 ? ((wearMinutes - 2) / 15) * 15 : -1
        let trend = trendOffsets.enumerated().compactMap { index, offset in
            sample(clear, slot: index, minute: wearMinutes - offset)
        }
        let history = (0..<3).compactMap { index in
            sample(clear, slot: index + trendOffsets.count, minute: historyMinute - 15 * index)
        }
        return Frame(wearMinutes: wearMinutes, trend: trend, history: history)
    }

    private static func sample(_ bytes: [UInt8], slot: Int, minute: Int) -> Sample? {
        let offset = slot * 4
        let packed = UInt32(word(bytes, at: offset)) | (UInt32(word(bytes, at: offset + 2)) << 16)
        let glucose = Int(packed & 0x3FFF)
        guard minute >= 0, glucose != 0 else { return nil }
        let temperature = Int((packed >> 14) & 0x0FFF) * 4
        let adjustment = Int((packed >> 26) & 0x1F) * 4
        return Sample(
            sensorMinute: minute,
            rawGlucose: glucose,
            rawTemperature: temperature,
            rawTemperatureAdjustment: packed >> 31 == 0 ? adjustment : -adjustment
        )
    }

    private static func word(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func keyBlock(uid: [UInt8], x: UInt16, y: UInt16) -> [UInt16] {
        transform([
            word(uid, at: 4) &+ x &+ y,
            word(uid, at: 2),
            word(uid, at: 0) &+ (x &* 2),
            0x241A ^ 0x14C6
        ])
    }

    private static func transform(_ input: [UInt16]) -> [UInt16] {
        func step(_ value: UInt16) -> UInt16 {
            var result = value >> 2
            if value & 1 != 0 { result ^= 0x6860 }
            if value & 2 != 0 { result ^= 0xA0C5 }
            return result
        }

        let r0 = step(input[0]) ^ input[3]
        let r1 = step(r0) ^ input[2]
        let r2 = step(r1) ^ input[1]
        let r3 = step(r2) ^ input[0]
        let r4 = step(r3)
        let r5 = step(r4 ^ r0)
        let r6 = step(r5 ^ r1)
        let r7 = step(r6 ^ r2)
        return [r3 ^ r7, r2 ^ r6, r1 ^ r5, r0 ^ r4]
    }

    private static func checksum(_ bytes: ArraySlice<UInt8>) -> UInt16 {
        // The Libre wire checksum reads each input byte least-significant bit first.
        var crc: UInt16 = 0xFFFF
        for byte in bytes {
            for bit in 0..<8 {
                let feedback = (crc >> 15) ^ (UInt16(byte >> bit) & 1)
                crc = (crc << 1) ^ (feedback == 0 ? 0 : 0x1021)
            }
        }
        return crc
    }
}
