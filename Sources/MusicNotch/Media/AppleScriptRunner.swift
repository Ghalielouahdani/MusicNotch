import Foundation

/// A Sendable copy of an Apple Event result, so it can leave the script queue.
enum ScriptValue: Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case data(Data)
    case list([ScriptValue])
    case missing

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var double: Double? {
        switch self {
        case .number(let value): value
        case .string(let value): Double(value)
        default: nil
        }
    }

    var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var data: Data? {
        if case .data(let value) = self { return value }
        return nil
    }

    var list: [ScriptValue] {
        if case .list(let value) = self { return value }
        return []
    }

    subscript(index: Int) -> ScriptValue {
        let items = list
        return items.indices.contains(index) ? items[index] : .missing
    }

    init(_ descriptor: NSAppleEventDescriptor) {
        switch descriptor.descriptorType {
        case fourCharCode("list"):
            let count = descriptor.numberOfItems
            let items = count > 0 ? (1...count).compactMap { descriptor.atIndex($0) } : []
            self = .list(items.map(ScriptValue.init))
        case fourCharCode("utxt"), fourCharCode("TEXT"), fourCharCode("utf8"):
            self = .string(descriptor.stringValue ?? "")
        case fourCharCode("long"), fourCharCode("shor"), fourCharCode("comp"),
             fourCharCode("magn"), fourCharCode("doub"), fourCharCode("sing"):
            self = .number(descriptor.doubleValue)
        case fourCharCode("true"):
            self = .bool(true)
        case fourCharCode("fals"):
            self = .bool(false)
        case fourCharCode("bool"):
            self = .bool(descriptor.booleanValue)
        case fourCharCode("null"):
            self = .missing
        case fourCharCode("type") where descriptor.typeCodeValue == fourCharCode("msng"):
            self = .missing
        case fourCharCode("tdta"), fourCharCode("JPEG"), fourCharCode("PNGf"),
             fourCharCode("TIFF"), fourCharCode("GIFf"), fourCharCode("BMPf"):
            self = .data(descriptor.data)
        default:
            if let string = descriptor.stringValue {
                self = .string(string)
            } else {
                self = .data(descriptor.data)
            }
        }
    }
}

private func fourCharCode(_ string: String) -> FourCharCode {
    string.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
}

struct ScriptError: LocalizedError, Sendable {
    var number: Int
    var message: String

    /// The user said no (or hasn't been asked) in Privacy & Security › Automation.
    var isPermissionDenied: Bool { number == -1743 }

    var errorDescription: String? { message }

    init(number: Int, message: String) {
        self.number = number
        self.message = message
    }

    init(_ info: NSDictionary?) {
        number = (info?[NSAppleScript.errorNumber] as? Int) ?? -1
        message = (info?[NSAppleScript.errorMessage] as? String) ?? "The music app didn't respond."
    }
}

/// Runs AppleScript off the main thread, one script at a time.
///
/// Apple Events block until the target app answers, so they must never run on the
/// main thread: a slow reply would stall the notch animation.
final class AppleScriptRunner: @unchecked Sendable {
    static let shared = AppleScriptRunner()

    private let queue = DispatchQueue(label: "MusicNotch.AppleScript", qos: .userInitiated)
    /// Compiled scripts, only touched on `queue`.
    private var compiled: [String: NSAppleScript] = [:]

    /// - Parameter cache: keep the compiled script. Pass `false` for one-off sources
    ///   that embed values, such as a seek position.
    @discardableResult
    func run(_ source: String, cache: Bool = true) async throws -> ScriptValue {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try self.execute(source, cache: cache) })
            }
        }
    }

    private func execute(_ source: String, cache: Bool) throws -> ScriptValue {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else {
                throw ScriptError(number: -1, message: "Couldn't create the script.")
            }
            var info: NSDictionary?
            guard fresh.compileAndReturnError(&info) else { throw ScriptError(info) }
            if cache { compiled[source] = fresh }
            script = fresh
        }
        var info: NSDictionary?
        let result = script.executeAndReturnError(&info)
        if let info { throw ScriptError(info) }
        return ScriptValue(result)
    }
}
