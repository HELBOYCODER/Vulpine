// JSONExtensions.swift
// Zero-dependency JSON helpers — parity with org.json.JSONObject's opt*() leniency.

import Foundation

enum JSONParsingError: Error { case invalid }

extension Dictionary where Key == String, Value == Any {
    /// `JSONObject.optString(key, fallback)` parity.
    func string(_ key: String, fallback: String = "") -> String {
        (self[key] as? String) ?? fallback
    }

    /// `JSONObject.optInt(key, fallback)` parity.
    func int(_ key: String, fallback: Int = 0) -> Int {
        switch self[key] {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string) ?? fallback
        default: return fallback
        }
    }

    /// `JSONObject.optLong(key, fallback)` parity.
    func int64(_ key: String, fallback: Int64 = 0) -> Int64 {
        switch self[key] {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string) ?? fallback
        default: return fallback
        }
    }

    /// `JSONObject.optBoolean(key, fallback)` parity.
    func bool(_ key: String, fallback: Bool = false) -> Bool {
        (self[key] as? Bool) ?? fallback
    }

    /// `JSONObject.optJSONObject(key)` parity.
    func object(_ key: String) -> [String: Any]? {
        self[key] as? [String: Any]
    }

    /// `JSONObject.optJSONArray(key)` parity.
    func array(_ key: String) -> [Any]? {
        self[key] as? [Any]
    }

    /// Returns nil when the key is missing, or when the JSON value is explicitly null.
    func optionalInt64(_ key: String) -> Int64? {
        switch self[key] {
        case let number as NSNumber:
            let value = number.int64Value
            return value >= 0 ? value : nil
        case nil, is NSNull:
            return nil
        default:
            return nil
        }
    }
}

extension String {
    /// Parses JSON into a dictionary, or throws.
    func asJSON() throws -> [String: Any] {
        guard let data = data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw JSONParsingError.invalid }
        return object
    }
}

extension Data {
    func asJSON() throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: self) as? [String: Any]
        else { throw JSONParsingError.invalid }
        return object
    }
}

extension Array where Element == Any {
    /// `JSONArray.getJSONObject(i)` parity.
    func object(at index: Int) -> [String: Any]? {
        guard index >= 0, index < count else { return nil }
        return self[index] as? [String: Any]
    }
}
