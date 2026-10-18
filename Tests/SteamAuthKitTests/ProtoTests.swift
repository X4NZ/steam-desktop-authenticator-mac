import Foundation
import Testing

@testable import SteamAuthKit

/// Expected byte strings here were computed by hand from the protobuf wire-format
/// spec, independently of the encoder under test.
struct ProtoWriterTests {

    @Test("Strings encode as tag, length, bytes")
    func stringField() {
        var writer = ProtoWriter()
        writer.string(1, "test")
        #expect(writer.data.hexString == "0a0474657374")
    }

    @Test("Multi-byte varints encode little-endian base 128")
    func varintField() {
        var writer = ProtoWriter()
        writer.varint(4, UInt64(300))
        #expect(writer.data.hexString == "20ac02")
    }

    @Test("Negative int32 fields are sign-extended to ten bytes")
    func negativeInt32() {
        // os_type is EOSType.AndroidUnknown = -500. A naive encoder that clamps
        // or truncates this makes Steam reject the device as non-mobile.
        var writer = ProtoWriter()
        writer.int32(3, -500)
        #expect(writer.data.hexString == "188cfcffffffffffffff01")
    }

    @Test("fixed64 fields use eight little-endian bytes")
    func fixed64Field() {
        var writer = ProtoWriter()
        writer.fixed64(2, 1)
        #expect(writer.data.hexString == "110100000000000000")
    }

    @Test("Nested messages are length-delimited")
    func nestedMessage() {
        var writer = ProtoWriter()
        writer.message(9) { details in
            details.string(1, "Mac")
            details.varint(2, 3)
            details.int32(3, -500)
        }
        #expect(writer.data.hexString == "4a120a034d61631003188cfcffffffffffffff01")
    }

    @Test("Zero and empty values are omitted, as proto3 expects")
    func defaultsOmitted() {
        var writer = ProtoWriter()
        writer.varint(1, UInt64(0))
        writer.string(2, "")
        writer.string(3, nil)
        writer.bool(4, false)
        #expect(writer.data.isEmpty)
    }
}

struct ProtoReaderTests {

    @Test("Reader recovers every field the writer produced")
    func roundTrip() {
        var writer = ProtoWriter()
        writer.varint(1, UInt64(12_345_678_901))
        writer.bytes(2, Data([0xDE, 0xAD, 0xBE, 0xEF]))
        writer.string(6, "account")
        writer.bool(5, true)

        let message = ProtoMessage(writer.data)
        #expect(message.varint(1) == 12_345_678_901)
        #expect(message.bytes(2) == Data([0xDE, 0xAD, 0xBE, 0xEF]))
        #expect(message.string(6) == "account")
        #expect(message.bool(5))
        #expect(message.string(99) == nil)
    }

    @Test("Repeated nested messages are all returned")
    func repeatedMessages() {
        // Shaped like allowed_confirmations in a begin-session response.
        var writer = ProtoWriter()
        for (type, note) in [(3, "device"), (2, "e***@example.com")] {
            writer.message(4) { confirmation in
                confirmation.varint(1, type)
                confirmation.string(2, note)
            }
        }

        let confirmations = ProtoMessage(writer.data).messages(4)
        #expect(confirmations.count == 2)
        #expect(confirmations[0].int(1) == 3)
        #expect(confirmations[1].string(2) == "e***@example.com")
    }

    @Test("Floats decode from fixed32 fields")
    func floatField() {
        // interval = 5.0 as IEEE-754 little-endian, field 3 wire type 5.
        let data = Data(hexString: "1d0000a040")!
        #expect(ProtoMessage(data).float(3) == 5.0)
    }

    @Test("Truncated input stops cleanly instead of crashing")
    func truncatedInput() {
        var writer = ProtoWriter()
        writer.string(1, "a long enough string to truncate")
        let truncated = writer.data.prefix(6)

        let message = ProtoMessage(Data(truncated))
        #expect(message.string(1) == nil)
    }

    @Test("Garbage input does not crash the decoder")
    func garbageInput() {
        for _ in 0 ..< 100 {
            let message = ProtoMessage(Crypto.randomBytes(64))
            _ = message.string(1)
            _ = message.varint(2)
            _ = message.messages(4)
        }
    }
}
