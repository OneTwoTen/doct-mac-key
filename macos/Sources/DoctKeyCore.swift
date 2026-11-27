import Foundation

/// The result operations the engine can report (see docs/SPEC.md §3).
enum KeyOp: String {
    case append
    case replace
    case commit
    case pass
    case none
    case state
}

/// Decoded form of the JSON object returned by every engine entry point.
///
/// Every field is optional on the wire (commands such as `toggle_mode` may omit
/// values they did not change), so decoding is forgiving: anything missing or
/// malformed falls back to a safe default instead of trapping.
struct KeyResult {
    var op: KeyOp = .none
    var text: String = ""
    var word: String = ""
    var raw: String = ""
    var composing: Bool = false
    var consumed: Bool = false
    var mode: String = "vi"
    var method: String = "telex"
    var toneStyle: String = "modern"
    var smart: Bool = true
    var changed: Bool = false

    var isCommit: Bool { op == .commit }

    static func decode(_ json: String) -> KeyResult {
        guard !json.isEmpty else { return KeyResult() }
        var copy = json
        return copy.withUTF8 { buffer in
            decode(utf8Bytes: buffer)
        }
    }

    /// Fast zero-Foundation-overhead UTF-8 JSON object decoder for engine results.
    static func decode(utf8Bytes bytes: UnsafeBufferPointer<UInt8>) -> KeyResult {
        guard !bytes.isEmpty else { return KeyResult() }
        var parser = ResultJSONParser(bytes: bytes)
        return parser.parseObject() ?? KeyResult()
    }
}

private struct ResultJSONParser {
    let bytes: UnsafeBufferPointer<UInt8>
    var index: Int = 0

    private var count: Int { bytes.count }

    mutating func parseObject() -> KeyResult? {
        skipWhitespace()
        guard consume(0x7B) else { return nil } // '{'
        skipWhitespace()

        var result = KeyResult()
        if peek() == 0x7D { // '}'
            index += 1
            skipWhitespace()
            return index == count ? result : nil
        }

        while true {
            skipWhitespace()
            guard let keyToken = parseStringToken() else { return nil }
            skipWhitespace()
            guard consume(0x3A) else { return nil } // ':'
            skipWhitespace()

            if !keyToken.hasEscape {
                if equalsASCII(keyToken, "op") {
                    if !parseOpField(into: &result) { return nil }
                } else if equalsASCII(keyToken, "text") {
                    if let s = parseOptionalString() {
                        result.text = s
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "word") {
                    if let s = parseOptionalString() {
                        result.word = s
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "raw") {
                    if let s = parseOptionalString() {
                        result.raw = s
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "composing") {
                    if let b = parseOptionalBool() {
                        result.composing = b
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "consumed") {
                    if let b = parseOptionalBool() {
                        result.consumed = b
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "mode") {
                    if !parseNonEmptyStringField(into: &result.mode, choices: ("vi", "en")) { return nil }
                } else if equalsASCII(keyToken, "method") {
                    if !parseNonEmptyStringField(into: &result.method, choices: ("telex", "vni")) { return nil }
                } else if equalsASCII(keyToken, "tone_style") {
                    if !parseNonEmptyStringField(into: &result.toneStyle, choices: ("modern", "traditional")) { return nil }
                } else if equalsASCII(keyToken, "smart") {
                    if let b = parseOptionalBool() {
                        result.smart = b
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else if equalsASCII(keyToken, "changed") {
                    if let b = parseOptionalBool() {
                        result.changed = b
                    } else if !isCurrentValueValidAndSkipped() {
                        return nil
                    }
                } else {
                    guard skipValue(depth: 0) else { return nil }
                }
            } else {
                guard let key = decodeStringToken(keyToken) else { return nil }
                if !parseNamedKey(key, into: &result) { return nil }
            }

            skipWhitespace()
            guard let next = peek() else { return nil }
            if next == 0x2C { // ','
                index += 1
                continue
            }
            if next == 0x7D { // '}'
                index += 1
                skipWhitespace()
                return index == count ? result : nil
            }
            return nil
        }
    }

    private mutating func parseNamedKey(_ key: String, into result: inout KeyResult) -> Bool {
        switch key {
        case "op":
            return parseOpField(into: &result)
        case "text":
            if let s = parseOptionalString() { result.text = s; return true }
            return isCurrentValueValidAndSkipped()
        case "word":
            if let s = parseOptionalString() { result.word = s; return true }
            return isCurrentValueValidAndSkipped()
        case "raw":
            if let s = parseOptionalString() { result.raw = s; return true }
            return isCurrentValueValidAndSkipped()
        case "composing":
            if let b = parseOptionalBool() { result.composing = b; return true }
            return isCurrentValueValidAndSkipped()
        case "consumed":
            if let b = parseOptionalBool() { result.consumed = b; return true }
            return isCurrentValueValidAndSkipped()
        case "mode":
            return parseNonEmptyStringField(into: &result.mode, choices: ("vi", "en"))
        case "method":
            return parseNonEmptyStringField(into: &result.method, choices: ("telex", "vni"))
        case "tone_style":
            return parseNonEmptyStringField(into: &result.toneStyle, choices: ("modern", "traditional"))
        case "smart":
            if let b = parseOptionalBool() { result.smart = b; return true }
            return isCurrentValueValidAndSkipped()
        case "changed":
            if let b = parseOptionalBool() { result.changed = b; return true }
            return isCurrentValueValidAndSkipped()
        default:
            return skipValue(depth: 0)
        }
    }

    private mutating func parseOpField(into result: inout KeyResult) -> Bool {
        guard peek() == 0x22 else { return skipValue(depth: 0) }
        guard let token = parseStringToken() else { return false }
        if !token.hasEscape {
            if equalsASCII(token, "append") { result.op = .append }
            else if equalsASCII(token, "replace") { result.op = .replace }
            else if equalsASCII(token, "commit") { result.op = .commit }
            else if equalsASCII(token, "pass") { result.op = .pass }
            else if equalsASCII(token, "none") { result.op = .none }
            else if equalsASCII(token, "state") { result.op = .state }
            return true
        }
        guard let str = decodeStringToken(token) else { return false }
        if let op = KeyOp(rawValue: str) {
            result.op = op
        }
        return true
    }

    private mutating func parseNonEmptyStringField(into field: inout String,
                                                  choices: (StaticString, StaticString)) -> Bool {
        guard peek() == 0x22 else { return skipValue(depth: 0) }
        guard let token = parseStringToken() else { return false }
        if token.start == token.end { return true }
        if !token.hasEscape {
            if equalsASCII(token, choices.0) {
                field = String(describing: choices.0)
                return true
            }
            if equalsASCII(token, choices.1) {
                field = String(describing: choices.1)
                return true
            }
        }
        guard let str = decodeStringToken(token) else { return false }
        if !str.isEmpty {
            field = str
        }
        return true
    }

    private mutating func parseOptionalString() -> String? {
        guard peek() == 0x22 else { return nil }
        let saved = index
        guard let token = parseStringToken(), let decoded = decodeStringToken(token) else {
            index = saved
            return nil
        }
        return decoded
    }

    private mutating func parseOptionalBool() -> Bool? {
        if matchLiteral("true") { return true }
        if matchLiteral("false") { return false }
        return nil
    }

    private mutating func isCurrentValueValidAndSkipped() -> Bool {
        skipValue(depth: 0)
    }

    private struct StringToken {
        let start: Int
        let end: Int
        let hasEscape: Bool
    }

    private mutating func parseStringToken() -> StringToken? {
        guard consume(0x22) else { return nil }
        let start = index
        var hasEscape = false
        while index < count {
            let b = bytes[index]
            if b < 0x20 { return nil }
            if b == 0x22 {
                let end = index
                index += 1
                return StringToken(start: start, end: end, hasEscape: hasEscape)
            }
            if b == 0x5C {
                hasEscape = true
                index += 1
                guard index < count else { return nil }
                let esc = bytes[index]
                index += 1
                switch esc {
                case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                    break
                case 0x75:
                    guard index + 4 <= count,
                          hexDigit(bytes[index]) != nil,
                          hexDigit(bytes[index + 1]) != nil,
                          hexDigit(bytes[index + 2]) != nil,
                          hexDigit(bytes[index + 3]) != nil else { return nil }
                    index += 4
                default:
                    return nil
                }
            } else {
                index += 1
            }
        }
        return nil
    }

    private func decodeStringToken(_ token: StringToken) -> String? {
        if token.start == token.end { return "" }
        if !token.hasEscape {
            return String(decoding: bytes[token.start..<token.end], as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(token.end - token.start)
        var i = token.start
        while i < token.end {
            let b = bytes[i]
            if b != 0x5C {
                out.append(b)
                i += 1
                continue
            }
            i += 1
            let esc = bytes[i]
            i += 1
            switch esc {
            case 0x22: out.append(0x22)
            case 0x5C: out.append(0x5C)
            case 0x2F: out.append(0x2F)
            case 0x62: out.append(0x08)
            case 0x66: out.append(0x0C)
            case 0x6E: out.append(0x0A)
            case 0x72: out.append(0x0D)
            case 0x74: out.append(0x09)
            case 0x75:
                guard let u1 = parseHex4(at: i) else { return nil }
                i += 4
                if (0xD800...0xDBFF).contains(u1) {
                    guard i + 6 <= token.end,
                          bytes[i] == 0x5C,
                          bytes[i + 1] == 0x75,
                          let u2 = parseHex4(at: i + 2),
                          (0xDC00...0xDFFF).contains(u2) else {
                        return nil
                    }
                    i += 6
                    let cp = 0x10000 + ((UInt32(u1) - 0xD800) << 10) + (UInt32(u2) - 0xDC00)
                    guard let scalar = Unicode.Scalar(cp) else { return nil }
                    for u in scalar.utf8 { out.append(u) }
                } else if (0xDC00...0xDFFF).contains(u1) {
                    return nil
                } else {
                    guard let scalar = Unicode.Scalar(UInt32(u1)) else { return nil }
                    for u in scalar.utf8 { out.append(u) }
                }
            default:
                return nil
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private func parseHex4(at pos: Int) -> UInt16? {
        guard pos + 4 <= count,
              let h0 = hexDigit(bytes[pos]),
              let h1 = hexDigit(bytes[pos + 1]),
              let h2 = hexDigit(bytes[pos + 2]),
              let h3 = hexDigit(bytes[pos + 3]) else { return nil }
        return (UInt16(h0) << 12) | (UInt16(h1) << 8) | (UInt16(h2) << 4) | UInt16(h3)
    }

    private func hexDigit(_ b: UInt8) -> UInt8? {
        switch b {
        case 0x30...0x39: return b - 0x30
        case 0x41...0x46: return b - 0x41 + 10
        case 0x61...0x66: return b - 0x61 + 10
        default: return nil
        }
    }

    private func equalsASCII(_ token: StringToken, _ literal: StaticString) -> Bool {
        let len = token.end - token.start
        return literal.withUTF8Buffer { lit in
            guard lit.count == len else { return false }
            for i in 0..<len where bytes[token.start + i] != lit[i] {
                return false
            }
            return true
        }
    }

    private mutating func skipValue(depth: Int) -> Bool {
        guard depth <= 32 else { return false }
        skipWhitespace()
        guard let b = peek() else { return false }
        switch b {
        case 0x22: // string
            return parseStringToken() != nil
        case 0x7B: // '{'
            index += 1
            skipWhitespace()
            if peek() == 0x7D {
                index += 1
                return true
            }
            while true {
                skipWhitespace()
                guard parseStringToken() != nil else { return false }
                skipWhitespace()
                guard consume(0x3A) else { return false }
                guard skipValue(depth: depth + 1) else { return false }
                skipWhitespace()
                guard let next = peek() else { return false }
                if next == 0x2C {
                    index += 1
                    continue
                }
                if next == 0x7D {
                    index += 1
                    return true
                }
                return false
            }
        case 0x5B: // '['
            index += 1
            skipWhitespace()
            if peek() == 0x5D {
                index += 1
                return true
            }
            while true {
                guard skipValue(depth: depth + 1) else { return false }
                skipWhitespace()
                guard let next = peek() else { return false }
                if next == 0x2C {
                    index += 1
                    continue
                }
                if next == 0x5D {
                    index += 1
                    return true
                }
                return false
            }
        case 0x74:
            return matchLiteral("true")
        case 0x66:
            return matchLiteral("false")
        case 0x6E:
            return matchLiteral("null")
        case 0x2D, 0x30...0x39:
            return skipNumber()
        default:
            return false
        }
    }

    private mutating func skipNumber() -> Bool {
        if peek() == 0x2D { index += 1 }
        guard let first = peek() else { return false }
        if first == 0x30 {
            index += 1
        } else if (0x31...0x39).contains(first) {
            index += 1
            while let b = peek(), (0x30...0x39).contains(b) { index += 1 }
        } else {
            return false
        }
        if peek() == 0x2E {
            index += 1
            guard let b = peek(), (0x30...0x39).contains(b) else { return false }
            while let d = peek(), (0x30...0x39).contains(d) { index += 1 }
        }
        if let e = peek(), e == 0x65 || e == 0x45 {
            index += 1
            if let sign = peek(), sign == 0x2B || sign == 0x2D { index += 1 }
            guard let b = peek(), (0x30...0x39).contains(b) else { return false }
            while let d = peek(), (0x30...0x39).contains(d) { index += 1 }
        }
        return true
    }

    private func peek() -> UInt8? {
        index < count ? bytes[index] : nil
    }

    private mutating func consume(_ expected: UInt8) -> Bool {
        guard index < count, bytes[index] == expected else { return false }
        index += 1
        return true
    }

    private mutating func skipWhitespace() {
        while index < count {
            let b = bytes[index]
            if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                index += 1
            } else {
                break
            }
        }
    }

    private mutating func matchLiteral(_ literal: StaticString) -> Bool {
        literal.withUTF8Buffer { lit in
            guard index + lit.count <= count else { return false }
            for i in 0..<lit.count where bytes[index + i] != lit[i] {
                return false
            }
            index += lit.count
            return true
        }
    }
}

/// Thin, memory-safe Swift wrapper around the Rust C ABI in core/include/doctkey.h.
///
/// Ownership rule from the header: every `char *` returned by the engine must be
/// released with `doctkey_string_free()`. `takeResult` is the single place that
/// does that, so no leaked engine strings can escape this type.
///
/// The engine is not thread-safe; use one instance from one thread (the main
/// thread in the app, the only thread in the fixture runner).
final class DoctKeyCore {
    private var engine: OpaquePointer?

    init(configJSON: String = "{}") {
        engine = configJSON.withCString { doctkey_engine_new($0) }
    }

    deinit {
        if let engine {
            doctkey_engine_free(engine)
        }
    }

    var isReady: Bool { engine != nil }

    var version: String {
        guard let raw = doctkey_version() else { return "unknown" }
        return String(cString: raw)
    }

    /// Merges settings into the engine config. Returns false for invalid JSON
    /// (the previous config is kept by the engine).
    @discardableResult
    func setConfig(_ configJSON: String) -> Bool {
        guard let engine else { return false }
        let status = configJSON.withCString { doctkey_engine_set_config(engine, $0) }
        return status == 1
    }

    func feedChar(_ scalar: UInt32, flags: UInt32 = 0) -> KeyResult {
        guard let engine else { return KeyResult() }
        return takeResult(doctkey_feed_char(engine, scalar, flags))
    }

    /// 1 = backspace, 2 = forward delete, 3 = escape, 4 = return, 5 = tab,
    /// 6 = caret movement / other command key.
    func feedKey(_ key: UInt32) -> KeyResult {
        guard let engine else { return KeyResult() }
        return takeResult(doctkey_feed_key(engine, key))
    }

    func commit() -> KeyResult {
        guard let engine else { return KeyResult() }
        return takeResult(doctkey_commit(engine))
    }

    /// Drops the composition state without touching the screen.
    func reset() {
        guard let engine else { return }
        doctkey_reset(engine)
    }

    func command(_ json: String) -> KeyResult {
        guard let engine else { return KeyResult() }
        return json.withCString { takeResult(doctkey_command(engine, $0)) }
    }

    func status() -> KeyResult {
        guard let engine else { return KeyResult() }
        return takeResult(doctkey_status(engine))
    }

    /// Decodes + frees an engine-owned C string directly from its UTF-8 buffer.
    private func takeResult(_ pointer: UnsafeMutablePointer<CChar>?) -> KeyResult {
        guard let pointer else { return KeyResult() }
        defer { doctkey_string_free(pointer) }
        let length = Int(strlen(pointer))
        return pointer.withMemoryRebound(to: UInt8.self, capacity: length) { bytes in
            KeyResult.decode(utf8Bytes: UnsafeBufferPointer(start: bytes, count: length))
        }
    }
}
