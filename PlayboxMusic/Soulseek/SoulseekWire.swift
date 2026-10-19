import Foundation

/// Soulseek wire encoding: little-endian integers and length-prefixed strings.
struct SlskWriter {
    private(set) var data = Data()

    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func bool(_ value: Bool) { u8(value ? 1 : 0) }

    mutating func u32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func u64(_ value: UInt64) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    mutating func raw(_ bytes: Data) { data.append(bytes) }

    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        u32(UInt32(bytes.count))
        data.append(contentsOf: bytes)
    }

    /// Server and peer messages: uint32 length, uint32 code, payload.
    static func message(code: UInt32, _ build: (inout SlskWriter) -> Void = { _ in }) -> Data {
        var body = SlskWriter()
        body.u32(code)
        build(&body)
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count))
        framed.data.append(body.data)
        return framed.data
    }

    /// Peer init messages: uint32 length, uint8 code, payload.
    static func initMessage(code: UInt8, _ build: (inout SlskWriter) -> Void) -> Data {
        var body = SlskWriter()
        body.u8(code)
        build(&body)
        var framed = SlskWriter()
        framed.u32(UInt32(body.data.count))
        framed.data.append(body.data)
        return framed.data
    }
}

struct SlskReader {
    enum ReadError: Error { case truncated }

    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    var remaining: Int { bytes.count - offset }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw ReadError.truncated }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func bool() throws -> Bool { try u8() != 0 }

    mutating func u32() throws -> UInt32 {
        guard remaining >= 4 else { throw ReadError.truncated }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * UInt32(index)) }
        offset += 4
        return value
    }

    mutating func u64() throws -> UInt64 {
        guard remaining >= 8 else { throw ReadError.truncated }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * UInt64(index)) }
        offset += 8
        return value
    }

    mutating func string() throws -> String {
        let length = Int(try u32())
        guard length >= 0, remaining >= length else { throw ReadError.truncated }
        let slice = bytes[offset..<(offset + length)]
        offset += length
        // Older clients send Latin-1.
        return String(bytes: slice, encoding: .utf8) ?? String(bytes: slice, encoding: .isoLatin1) ?? ""
    }

    mutating func skip(_ count: Int) throws {
        guard remaining >= count else { throw ReadError.truncated }
        offset += count
    }

    mutating func rest() -> Data {
        defer { offset = bytes.count }
        return Data(bytes[offset...])
    }
}

enum SlskZlib {
    enum ZlibError: Error { case invalid }

    /// Soulseek compresses with zlib framing; Foundation handles raw DEFLATE.
    static func inflate(_ data: Data) throws -> Data {
        let bytes = Array(data)
        guard bytes.count > 6, bytes[0] & 0x0F == 8 else { throw ZlibError.invalid }
        let raw = Data(bytes[2..<(bytes.count - 4)])
        return try (raw as NSData).decompressed(using: .zlib) as Data
    }

    static func deflate(_ data: Data) throws -> Data {
        let raw = try (data as NSData).compressed(using: .zlib) as Data
        var output = Data([0x78, 0x9C])
        output.append(raw)
        let checksum = adler32(data)
        withUnsafeBytes(of: checksum.bigEndian) { output.append(contentsOf: $0) }
        return output
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        return (b << 16) | a
    }
}

enum SlskAddress {
    /// Soulseek sends IPv4 addresses as a little-endian uint32 whose most
    /// significant byte is the first octet.
    static func string(from ip: UInt32) -> String {
        "\((ip >> 24) & 0xFF).\((ip >> 16) & 0xFF).\((ip >> 8) & 0xFF).\(ip & 0xFF)"
    }
}
