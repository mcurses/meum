// Hand-rolled argument parsing for the `meum` CLI (no external dependencies).
import Foundation

public enum CLIError: Error, CustomStringConvertible {
    /// Bad invocation: exit code 2.
    case usage(String)
    /// The request reached the server and failed, or local work failed: exit code 1.
    case failure(String)
    /// Nothing listening: exit code 3.
    case unreachable(String)

    public var description: String {
        switch self {
        case .usage(let m), .failure(let m), .unreachable(let m): return m
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .failure: return 1
        case .usage: return 2
        case .unreachable: return 3
        }
    }
}

struct ParsedArgs {
    var positionals: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []

    func value(_ name: String) -> String? { values[name]?.last }
    func all(_ name: String) -> [String] { values[name] ?? [] }
    func has(_ name: String) -> Bool { flags.contains(name) }

    func int(_ name: String) throws -> Int? {
        guard let v = value(name) else { return nil }
        guard let n = Int(v) else { throw CLIError.usage("--\(name) expects a number, got '\(v)'") }
        return n
    }

    /// Parses `--name value`, `--name=value`, boolean `--name`, and `--` (rest is positional).
    /// Unknown options are an error, so typos never get silently ignored.
    static func parse(_ args: [String], valueOptions: Set<String> = [], boolOptions: Set<String> = []) throws -> ParsedArgs {
        var p = ParsedArgs()
        var i = 0
        var rest = false
        while i < args.count {
            let a = args[i]
            i += 1
            if rest || !a.hasPrefix("-") || a == "-" { p.positionals.append(a); continue }
            if a == "--" { rest = true; continue }
            guard a.hasPrefix("--") else { throw CLIError.usage("unknown option '\(a)'") }
            var name = String(a.dropFirst(2))
            var inline: String?
            if let eq = name.firstIndex(of: "=") {
                inline = String(name[name.index(after: eq)...])
                name = String(name[..<eq])
            }
            if valueOptions.contains(name) {
                if let inline { p.values[name, default: []].append(inline) }
                else {
                    guard i < args.count else { throw CLIError.usage("--\(name) needs a value") }
                    p.values[name, default: []].append(args[i])
                    i += 1
                }
            } else if boolOptions.contains(name) {
                if inline != nil { throw CLIError.usage("--\(name) takes no value") }
                p.flags.insert(name)
            } else {
                throw CLIError.usage("unknown option '--\(name)'")
            }
        }
        return p
    }

    func expectPositionals(_ names: [String], optional: Int = 0, command: String) throws {
        if positionals.count < names.count {
            throw CLIError.usage("usage: \(command) \(names.map { "<\($0)>" }.joined(separator: " "))")
        }
        if positionals.count > names.count + optional {
            throw CLIError.usage("unexpected argument '\(positionals[names.count + optional])' (usage: \(command))")
        }
    }
}
