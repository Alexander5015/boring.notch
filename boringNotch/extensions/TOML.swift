
import Foundation

nonisolated indirect enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case number(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table([String: TOMLValue])

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var doubleValue: Double? {
        switch self {
        case .number(let value): return value
        case .integer(let value): return Double(value)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .integer(let value): return value
        case .number(let value): return Int(exactly: value)
        default: return nil
        }
    }

    var tableValue: [String: TOMLValue]? {
        if case .table(let value) = self { return value }
        return nil
    }

    var arrayValue: [TOMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }
}

nonisolated struct TOMLParseError: Error, LocalizedError, Equatable {
    let line: Int
    let reason: String

    var errorDescription: String? { "Line \(line): \(reason)" }
}

nonisolated enum TOML {

    static func parse(_ text: String) throws -> [String: TOMLValue] {
        var root: [String: TOMLValue] = [:]
        var path: [String] = []

        let lines = Array(text.split(separator: "\n", omittingEmptySubsequences: false))
        var cursor = 0

        while cursor < lines.count {
            let number = cursor + 1
            let raw = lines[cursor]
            cursor += 1
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("[[") {
                guard line.hasSuffix("]]") else {
                    throw TOMLParseError(line: number, reason: "unterminated array-of-tables header")
                }
                let key = try keyPath(String(line.dropFirst(2).dropLast(2)), line: number)
                root = try appendTableElement(to: root, at: key, line: number)
                path = key

            } else if line.hasPrefix("[") {
                guard line.hasSuffix("]") else {
                    throw TOMLParseError(line: number, reason: "unterminated table header")
                }
                path = try keyPath(String(line.dropFirst().dropLast()), line: number)
                root = try ensuringTable(in: root, at: path, line: number)

            } else {
                guard let equals = line.firstIndex(of: "=") else {
                    throw TOMLParseError(line: number, reason: "expected `key = value`")
                }
                let key = String(line[..<equals]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else {
                    throw TOMLParseError(line: number, reason: "empty key")
                }
                var rawValue = String(line[line.index(after: equals)...])
                    .trimmingCharacters(in: .whitespaces)
                while rawValue.hasPrefix("["), !rawValue.hasSuffix("]"), cursor < lines.count {
                    let continuation = stripComment(lines[cursor]).trimmingCharacters(in: .whitespaces)
                    cursor += 1
                    rawValue += " " + continuation
                }
                let component = try keyPath(key, line: number)
                root = try setting(
                    try value(rawValue, line: number),
                    in: root, at: path + component, line: number
                )
            }
        }
        return root
    }

    private static func stripComment(_ line: Substring) -> String {
        var inString = false
        var escaped = false
        var out = ""
        for character in line {
            if escaped {
                out.append(character)
                escaped = false
            } else if character == "\\", inString {
                out.append(character)
                escaped = true
            } else if character == "\"" {
                inString.toggle()
                out.append(character)
            } else if character == "#", !inString {
                break
            } else {
                out.append(character)
            }
        }
        return out
    }

    private static func value(_ raw: String, line: Int) throws -> TOMLValue {
        if raw.hasPrefix("\"") { return .string(try string(raw, line: line)) }
        if raw.hasPrefix("[") { return .array(try array(raw, line: line)) }
        if raw == "true" { return .boolean(true) }
        if raw == "false" { return .boolean(false) }
        if let integer = Int(raw) { return .integer(integer) }
        if let number = Double(raw) { return .number(number) }
        throw TOMLParseError(line: line, reason: "unsupported value `\(raw)`")
    }

    private static func string(_ raw: String, line: Int) throws -> String {
        var out = ""
        var escaped = false
        var closed = false
        for character in raw.dropFirst() {
            if escaped {
                switch character {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                default: out.append(character)
                }
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                closed = true
                break
            } else {
                out.append(character)
            }
        }
        guard closed else { throw TOMLParseError(line: line, reason: "unterminated string") }
        return out
    }

    private static func array(_ raw: String, line: Int) throws -> [TOMLValue] {
        guard raw.hasSuffix("]") else {
            throw TOMLParseError(line: line, reason: "unterminated array")
        }
        var values: [TOMLValue] = []
        var current = ""
        var inString = false
        var escaped = false

        func flush() throws {
            let piece = current.trimmingCharacters(in: .whitespaces)
            current = ""
            guard !piece.isEmpty else { return }
            values.append(try value(piece, line: line))
        }

        for character in raw.dropFirst().dropLast() {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", inString {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                inString.toggle()
                current.append(character)
            } else if character == ",", !inString {
                try flush()
            } else {
                current.append(character)
            }
        }
        try flush()
        return values
    }

    private static func keyPath(_ key: String, line: Int) throws -> [String] {
        let parts = key.split(separator: ".")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { throw TOMLParseError(line: line, reason: "empty key") }
        return parts
    }

    private static func setting(
        _ newValue: TOMLValue,
        in root: [String: TOMLValue],
        at path: [String],
        line: Int
    ) throws -> [String: TOMLValue] {
        guard let head = path.first else {
            throw TOMLParseError(line: line, reason: "missing key")
        }
        if path.count == 1 {
            var result = root
            guard result[head] == nil else {
                throw TOMLParseError(line: line, reason: "duplicate key `\(head)`")
            }
            result[head] = newValue
            return result
        }
        let wasArray = root[head]?.arrayValue != nil
        var branch = try table(forKey: head, in: root, creating: true, line: line)
        branch = try setting(newValue, in: branch, at: Array(path.dropFirst()), line: line)
        return storing(branch, forKey: head, in: root, wasArray: wasArray)
    }

    private static func ensuringTable(
        in root: [String: TOMLValue],
        at path: [String],
        line: Int
    ) throws -> [String: TOMLValue] {
        guard let head = path.first else { return root }
        if path.count == 1 {
            var result = root
            if result[head] == nil { result[head] = .table([:]) }
            return result
        }
        let wasArray = root[head]?.arrayValue != nil
        var branch = try table(forKey: head, in: root, creating: true, line: line)
        branch = try ensuringTable(in: branch, at: Array(path.dropFirst()), line: line)
        return storing(branch, forKey: head, in: root, wasArray: wasArray)
    }

    private static func appendTableElement(
        to root: [String: TOMLValue],
        at path: [String],
        line: Int = 0
    ) throws -> [String: TOMLValue] {
        guard let head = path.first else { return root }
        if path.count == 1 {
            var result = root
            var entries = result[head]?.arrayValue ?? []
            entries.append(.table([:]))
            result[head] = .array(entries)
            return result
        }
        let wasArray = root[head]?.arrayValue != nil
        var branch = try table(forKey: head, in: root, creating: true, line: line)
        branch = try appendTableElement(to: branch, at: Array(path.dropFirst()), line: line)
        return storing(branch, forKey: head, in: root, wasArray: wasArray)
    }

    private static func table(
        forKey key: String,
        in root: [String: TOMLValue],
        creating: Bool,
        line: Int
    ) throws -> [String: TOMLValue] {
        switch root[key] {
        case .table(let table):
            return table
        case .array(let entries):
            guard case .table(let last)? = entries.last else {
                throw TOMLParseError(line: line, reason: "`\(key)` is an array of something other than tables")
            }
            return last
        case nil:
            guard creating else { throw TOMLParseError(line: line, reason: "missing table `\(key)`") }
            return [:]
        case .some(let other):
            throw TOMLParseError(line: line, reason: "`\(key)` is a \(kind(of: other)), not a table")
        }
    }

    private static func storing(
        _ table: [String: TOMLValue],
        forKey key: String,
        in root: [String: TOMLValue],
        wasArray: Bool
    ) -> [String: TOMLValue] {
        var result = root
        if wasArray, var entries = result[key]?.arrayValue, !entries.isEmpty {
            entries[entries.count - 1] = .table(table)
            result[key] = .array(entries)
        } else {
            result[key] = .table(table)
        }
        return result
    }

    private static func kind(of value: TOMLValue) -> String {
        switch value {
        case .string: "string"
        case .integer, .number: "number"
        case .boolean: "boolean"
        case .array: "array"
        case .table: "table"
        }
    }
}

nonisolated extension Dictionary where Key == String, Value == TOMLValue {
    func require(_ key: String) throws -> String {
        guard let value = string(key) else {
            throw TOMLParseError(line: 0, reason: "missing required key `\(key)`")
        }
        return value
    }

    func string(_ key: String) -> String? {
        guard let value = self[key]?.stringValue, !value.isEmpty else { return nil }
        return value
    }

    func number(_ key: String) -> Double? { self[key]?.doubleValue }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func table(_ key: String) -> [String: TOMLValue]? { self[key]?.tableValue }

    func tables(_ key: String) -> [[String: TOMLValue]] {
        (self[key]?.arrayValue ?? []).compactMap(\.tableValue)
    }

    func strings(_ key: String) -> [String] {
        (self[key]?.arrayValue ?? []).compactMap(\.stringValue)
    }
}
