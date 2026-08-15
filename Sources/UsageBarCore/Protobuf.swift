import Foundation

/// grpc-web frames and a protobuf wire reader. Only what Grok's weekly call needs —
/// no generated stubs, no package.
enum GrpcWeb {
    /// Empty request message: data flag + 4-byte zero length.
    static let emptyRequest = Data([0x00, 0x00, 0x00, 0x00, 0x00])

    /// First data-frame payload, or nil if the body is truncated, has no data
    /// frame, or the trailer says `grpc-status` other than 0. Status lives in
    /// the trailer frame (flag `0x80`), not in HTTP headers.
    static func dataMessage(from body: Data) -> Data? {
        guard let frames = frames(in: body) else { return nil }
        for frame in frames where frame.flag & 0x80 != 0 {
            if let status = trailerStatus(frame.payload), status != 0 { return nil }
        }
        return frames.first(where: { $0.flag & 0x80 == 0 })?.payload
    }

    static func encode(message: Data, trailerStatus: Int? = 0) -> Data {
        var out = frame(flag: 0x00, payload: message)
        if let trailerStatus {
            let text = "grpc-status:\(trailerStatus)\r\n"
            out.append(frame(flag: 0x80, payload: Data(text.utf8)))
        }
        return out
    }

    static func frame(flag: UInt8, payload: Data) -> Data {
        var out = Data([flag])
        var length = UInt32(payload.count).bigEndian
        out.append(Data(bytes: &length, count: 4))
        out.append(payload)
        return out
    }

    private struct Frame {
        var flag: UInt8
        var payload: Data
    }

    private static func frames(in body: Data) -> [Frame]? {
        var offset = 0
        var result: [Frame] = []
        while offset < body.count {
            guard offset + 5 <= body.count else { return nil }
            let flag = body[offset]
            let length = body[offset + 1..<offset + 5].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            offset += 5
            let end = offset + Int(length)
            guard end <= body.count else { return nil }
            result.append(Frame(flag: flag, payload: body.subdata(in: offset..<end)))
            offset = end
        }
        return result
    }

    private static func trailerStatus(_ payload: Data) -> Int? {
        guard let text = String(data: payload, encoding: .utf8) else { return nil }
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "grpc-status" else { continue }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}

enum Proto {
    struct Field: Equatable {
        var number: UInt64
        var value: Value
        enum Value: Equatable {
            case varint(UInt64)
            case fixed32(UInt32)
            case fixed64(UInt64)
            case bytes(Data)
        }
    }

    /// Nil if any field is truncated — including a varint whose continuation
    /// bit is set at the end of the buffer.
    static func decode(_ data: Data) -> [Field]? {
        var reader = Reader(data)
        var fields: [Field] = []
        while reader.hasMore {
            guard let field = reader.nextField() else { return nil }
            fields.append(field)
        }
        return fields
    }

    static func message(_ fields: [Field], _ number: UInt64) -> [Field]? {
        for field in fields {
            if field.number == number, case .bytes(let data) = field.value {
                return decode(data)
            }
        }
        return nil
    }

    static func varint(_ fields: [Field], _ number: UInt64) -> UInt64? {
        for field in fields {
            if field.number == number, case .varint(let value) = field.value { return value }
        }
        return nil
    }

    static func float(_ fields: [Field], _ number: UInt64) -> Float? {
        for field in fields {
            if field.number == number, case .fixed32(let bits) = field.value {
                return Float(bitPattern: bits)
            }
        }
        return nil
    }

    private struct Reader {
        let data: Data
        var offset = 0

        init(_ data: Data) { self.data = data }

        var hasMore: Bool { offset < data.count }

        mutating func nextField() -> Field? {
            guard let key = readVarint() else { return nil }
            let number = key >> 3
            let wire = key & 0x7
            switch wire {
            case 0:
                guard let value = readVarint() else { return nil }
                return Field(number: number, value: .varint(value))
            case 1:
                guard let bits = readFixed(8) else { return nil }
                return Field(number: number, value: .fixed64(bits))
            case 2:
                guard let length = readVarint(), let bytes = readBytes(Int(length)) else { return nil }
                return Field(number: number, value: .bytes(bytes))
            case 5:
                guard let bits = readFixed(4) else { return nil }
                return Field(number: number, value: .fixed32(UInt32(truncatingIfNeeded: bits)))
            default:
                return nil
            }
        }

        mutating func readVarint() -> UInt64? {
            var result: UInt64 = 0
            var shift = 0
            while shift < 64 {
                guard offset < data.count else { return nil }
                let byte = data[offset]
                offset += 1
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            return nil
        }

        mutating func readFixed(_ count: Int) -> UInt64? {
            guard let bytes = readBytes(count) else { return nil }
            var value: UInt64 = 0
            for (i, byte) in bytes.enumerated() {
                value |= UInt64(byte) << (8 * i)
            }
            return value
        }

        mutating func readBytes(_ count: Int) -> Data? {
            guard count >= 0, offset + count <= data.count else { return nil }
            let slice = data.subdata(in: offset..<(offset + count))
            offset += count
            return slice
        }
    }
}
