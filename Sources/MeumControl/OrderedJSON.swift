// Order- and spelling-preserving JSON for editing settings files without rewriting what we don't touch.
// Objects keep member order, numbers keep their source text, and strings keep their source escapes, so
// parse -> serialize is byte-identical for files written as `JSON.stringify(x, null, 2)` (which Claude Code does).
import Foundation

indirect enum OJ: Equatable {
    case null
    case bool(Bool)
    case number(String)
    /// `raw` is the source text between the quotes (escapes intact); nil for strings we create.
    case string(String, raw: String?)
    case array([OJ])
    case object([OMember])

    static func str(_ s: String) -> OJ { .string(s, raw: nil) }
}

struct OMember: Equatable {
    var key: String
    var rawKey: String?
    var value: OJ
    init(_ key: String, _ value: OJ, rawKey: String? = nil) { self.key = key; self.value = value; self.rawKey = rawKey }
}

extension OJ {
    var objectMembers: [OMember]? { if case .object(let m) = self { return m }; return nil }
    var arrayItems: [OJ]? { if case .array(let a) = self { return a }; return nil }
    var stringValue: String? { if case .string(let s, _) = self { return s }; return nil }

    func member(_ key: String) -> OJ? { objectMembers?.first(where: { $0.key == key })?.value }
}

struct OJParseError: Error, CustomStringConvertible {
    var message: String
    var offset: Int
    var description: String { "\(message) at byte \(offset)" }
}

enum OJParser {
    static func parse(_ text: String) throws -> OJ {
        var p = Parser(bytes: Array(text.utf8))
        p.skipWS()
        let v = try p.value()
        p.skipWS()
        if p.i != p.bytes.count { throw OJParseError(message: "unexpected trailing content", offset: p.i) }
        return v
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(bytes: [UInt8]) { self.bytes = bytes }

        mutating func skipWS() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        func err(_ m: String) -> OJParseError { OJParseError(message: m, offset: i) }

        mutating func value() throws -> OJ {
            guard i < bytes.count else { throw err("unexpected end") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try object()
            case UInt8(ascii: "["): return try array()
            case UInt8(ascii: "\""):
                let (s, raw) = try string()
                return .string(s, raw: raw)
            case UInt8(ascii: "t"): try lit("true"); return .bool(true)
            case UInt8(ascii: "f"): try lit("false"); return .bool(false)
            case UInt8(ascii: "n"): try lit("null"); return .null
            default: return try number()
            }
        }

        mutating func lit(_ s: String) throws {
            let u = Array(s.utf8)
            guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw err("bad literal") }
            i += u.count
        }

        mutating func number() throws -> OJ {
            let start = i
            while i < bytes.count, "-+0123456789.eE".utf8.contains(bytes[i]) { i += 1 }
            guard i > start else { throw err("unexpected character") }
            return .number(String(decoding: bytes[start..<i], as: UTF8.self))
        }

        mutating func string() throws -> (String, String) {
            i += 1 // opening quote
            let start = i
            var out = [UInt8]()
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") {
                    let raw = String(decoding: bytes[start..<i], as: UTF8.self)
                    i += 1
                    return (String(decoding: out, as: UTF8.self), raw)
                }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "u"):
                        var cp = try hex4()
                        if (0xD800..<0xDC00).contains(cp), i + 2 < bytes.count, bytes[i + 1] == 0x5C, bytes[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let lo = try hex4()
                            if (0xDC00..<0xE000).contains(lo) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00) }
                        }
                        out.append(contentsOf: Array(String(UnicodeScalar(cp) ?? "\u{FFFD}").utf8))
                    default: out.append(e) // " \ /
                    }
                    i += 1
                    continue
                }
                out.append(b)
                i += 1
            }
            throw err("unterminated string")
        }

        /// On entry `i` is at the 'u'; on exit at the last hex digit.
        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count else { throw err("bad \\u escape") }
            let h = String(decoding: bytes[i + 1...i + 4], as: UTF8.self)
            guard let v = UInt32(h, radix: 16) else { throw err("bad \\u escape") }
            i += 4
            return v
        }

        mutating func array() throws -> OJ {
            i += 1
            var items: [OJ] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array([]) }
            while true {
                skipWS()
                items.append(try value())
                skipWS()
                guard i < bytes.count else { throw err("unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw err("expected , or ]")
            }
        }

        mutating func object() throws -> OJ {
            i += 1
            var members: [OMember] = []
            skipWS()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object([]) }
            while true {
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw err("expected object key") }
                let (k, rawK) = try string()
                skipWS()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw err("expected :") }
                i += 1
                skipWS()
                let v = try value()
                members.append(OMember(k, v, rawKey: rawK))
                skipWS()
                guard i < bytes.count else { throw err("unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw err("expected , or }")
            }
        }
    }
}

enum OJWriter {
    /// `indent` is the unit ("  " or "\t"). Layout matches JSON.stringify(x, null, indent).
    static func write(_ v: OJ, indent: String = "  ") -> String {
        var out = ""
        emit(v, depth: 0, indent: indent, into: &out)
        return out
    }

    static func escape(_ s: String) -> String {
        var o = ""
        for u in s.unicodeScalars {
            switch u {
            case "\"": o += "\\\""
            case "\\": o += "\\\\"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            case "\t": o += "\\t"
            case "\u{08}": o += "\\b"
            case "\u{0C}": o += "\\f"
            default:
                if u.value < 0x20 { o += String(format: "\\u%04x", u.value) } else { o.unicodeScalars.append(u) }
            }
        }
        return o
    }

    private static func emit(_ v: OJ, depth: Int, indent: String, into out: inout String) {
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s, let raw): out += "\"" + (raw ?? escape(s)) + "\""
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (n, item) in items.enumerated() {
                out += String(repeating: indent, count: depth + 1)
                emit(item, depth: depth + 1, indent: indent, into: &out)
                out += n == items.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: depth) + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{\n"
            for (n, m) in members.enumerated() {
                out += String(repeating: indent, count: depth + 1)
                out += "\"" + (m.rawKey ?? escape(m.key)) + "\": "
                emit(m.value, depth: depth + 1, indent: indent, into: &out)
                out += n == members.count - 1 ? "\n" : ",\n"
            }
            out += String(repeating: indent, count: depth) + "}"
        }
    }
}
