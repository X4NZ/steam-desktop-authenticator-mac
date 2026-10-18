import Foundation

/// Steam is inconsistent about whether numbers arrive as JSON numbers or strings:
/// `/mobileconf/getlist` quotes its 64-bit ids, `AddAuthenticator` quotes
/// `server_time`, and maFiles written by SDA use bare numbers for the same fields.
/// These helpers accept either form so one model handles every source.
extension KeyedDecodingContainer {
    func lenientUInt64(_ key: Key) -> UInt64? {
        if let value = try? decodeIfPresent(UInt64.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return UInt64(text) }
        return nil
    }

    func lenientInt64(_ key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int64(text) }
        return nil
    }

    func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let text = try? decodeIfPresent(String.self, forKey: key) { return Int(text) }
        return nil
    }

    func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value != 0 }
        if let text = try? decodeIfPresent(String.self, forKey: key) {
            return text == "true" || text == "1"
        }
        return nil
    }

    func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        return nil
    }
}
