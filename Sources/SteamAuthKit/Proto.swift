import Foundation

/// A deliberately small protobuf encoder/decoder.
///
/// Steam's `IAuthenticationService` only speaks protobuf, so logging in needs
/// wire-format support. Rather than take on a protobuf dependency and a codegen
/// step for four messages, this handles the three wire types those messages use.
enum ProtoWireType: UInt8 {
    case varint = 0
    case fixed64 = 1
    case lengthDelimited = 2
    case fixed32 = 5
}

// MARK: - Writer

struct ProtoWriter {
    private(set) var data = Data()

    mutating func varint(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return } // proto3-style: skip defaults
        tag(field, .varint)
        appendVarint(value)
    }

    mutating func varint(_ field: Int, _ value: Int) {
        varint(field, UInt64(max(0, value)))
    }

    /// Signed 32-bit fields (e.g. `os_type`) are sign-extended to 64 bits on the
    /// wire, so negative values occupy the full ten-byte varint.
    mutating func int32(_ field: Int, _ value: Int32) {
        guard value != 0 else { return }
        tag(field, .varint)
        appendVarint(UInt64(bitPattern: Int64(value)))
    }

    mutating func bool(_ field: Int, _ value: Bool) {
        guard value else { return }
        tag(field, .varint)
        appendVarint(1)
    }

    mutating func fixed64(_ field: Int, _ value: UInt64) {
        guard value != 0 else { return }
        tag(field, .fixed64)
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func string(_ field: Int, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        bytes(field, Data(value.utf8))
    }

    mutating func bytes(_ field: Int, _ value: Data?) {
        guard let value, !value.isEmpty else { return }
        tag(field, .lengthDelimited)
        appendVarint(UInt64(value.count))
        data.append(value)
    }

    /// Embeds a nested message, e.g. `device_details`.
    mutating func message(_ field: Int, _ build: (inout ProtoWriter) -> Void) {
        var nested = ProtoWriter()
        build(&nested)
        bytes(field, nested.data)
    }

    private mutating func tag(_ field: Int, _ type: ProtoWireType) {
        appendVarint(UInt64(field) << 3 | UInt64(type.rawValue))
    }

    private mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            data.append(byte)
        } while remaining != 0
    }
}

// MARK: - Reader

/// Decoded message, indexed by field number. Repeated fields keep every value.
struct ProtoMessage {
    private var fields: [Int: [ProtoValue]] = [:]

    init(_ data: Data) {
        var cursor = ProtoCursor(data)
        while let (field, type) = cursor.readTag() {
            guard let value = cursor.readValue(type) else { break }
            fields[field, default: []].append(value)
        }
    }

    func varint(_ field: Int) -> UInt64? {
        if case .varint(let value) = fields[field]?.first { return value }
        if case .fixed64(let value) = fields[field]?.first { return value }
        return nil
    }

    func int(_ field: Int) -> Int? { varint(field).map { Int(bitPattern: UInt(truncatingIfNeeded: $0)) } }

    func bool(_ field: Int) -> Bool { (varint(field) ?? 0) != 0 }

    func bytes(_ field: Int) -> Data? {
        if case .bytes(let value) = fields[field]?.first { return value }
        return nil
    }

    func string(_ field: Int) -> String? {
        bytes(field).flatMap { String(data: $0, encoding: .utf8) }
    }

    func float(_ field: Int) -> Float? {
        if case .fixed32(let bits) = fields[field]?.first { return Float(bitPattern: bits) }
        return nil
    }

    /// Repeated nested messages, e.g. `allowed_confirmations`.
    func messages(_ field: Int) -> [ProtoMessage] {
        (fields[field] ?? []).compactMap { value in
            if case .bytes(let data) = value { return ProtoMessage(data) }
            return nil
        }
    }

    func message(_ field: Int) -> ProtoMessage? { messages(field).first }
}

private enum ProtoValue {
    case varint(UInt64)
    case fixed64(UInt64)
    case fixed32(UInt32)
    case bytes(Data)
}

private struct ProtoCursor {
    private let data: Data
    private var offset: Int

    init(_ data: Data) {
        self.data = data
        self.offset = 0
    }

    mutating func readTag() -> (field: Int, type: ProtoWireType)? {
        guard let key = readVarint(),
              let type = ProtoWireType(rawValue: UInt8(key & 0x07))
        else { return nil }
        return (Int(key >> 3), type)
    }

    mutating func readValue(_ type: ProtoWireType) -> ProtoValue? {
        switch type {
        case .varint:
            return readVarint().map { .varint($0) }
        case .fixed64:
            return readFixed(8).map { .fixed64($0.withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }) }
        case .fixed32:
            return readFixed(4).map { .fixed32($0.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }) }
        case .lengthDelimited:
            // Int(length) would trap on a length past Int.max, which is a crash
            // reachable from any malformed response Steam or a proxy returns.
            guard let length = readVarint(),
                  let count = Int(exactly: length),
                  let payload = readFixed(count)
            else { return nil }
            return .bytes(payload)
        }
    }

    private mutating func readVarint() -> UInt64? {
        var result: UInt64 = 0
        var shift: UInt64 = 0

        while offset < data.count {
            let byte = data[data.startIndex + offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { return nil }
        }
        return nil
    }

    private mutating func readFixed(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.count else { return nil }
        let start = data.startIndex + offset
        offset += count
        return Data(data[start ..< start + count])
    }
}
