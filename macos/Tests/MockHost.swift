import Foundation

/// A faithful mock of the macOS text system used by the fixture runner.
///
/// It stores the document as UTF-16 code units (the unit every `NSTextInputClient`
/// API uses) and tracks a caret plus the marked (pre-edit) range, mirroring how a
/// real `NSTextView` behaves:
///
/// * `setMarkedText` replaces the current marked range (or inserts at the caret),
///   then selects the new marked text;
/// * `commitMarkedText` replaces the marked range with plain text and clears it;
/// * `replaceTrailing(n, with:)` replaces the last n UTF-16 units before the caret;
/// * after every operation the caret sits at the end of the inserted text.
final class MockHost: TextHost {
    /// The document, as UTF-16 code units.
    private var units: [UInt16] = []
    /// Caret position, a UTF-16 offset into `units`.
    private(set) var caret: Int = 0
    /// Marked (pre-edit) range in UTF-16 units, nil when nothing is marked.
    private(set) var markedRange: NSRange?
    private(set) var markedText: String = ""

    /// The document text as seen by the application.
    var documentText: String {
        String(decoding: units, as: UTF16.self)
    }

    /// Convenience for tests that need to compare only the tail.
    var trailingComposition: String {
        guard let markedRange else { return "" }
        return String(decoding: units[markedRange.location..<NSMaxRange(markedRange)], as: UTF16.self)
    }

    // MARK: - TextHost

    func insertText(_ text: String) {
        let inserted = Array(text.utf16)
        if let range = markedRange {
            // Defensive: real clients replace the marked range on insertText.
            replace(range: range, with: inserted)
            clearMarked()
        } else {
            units.insert(contentsOf: inserted, at: caret)
            caret += inserted.count
        }
    }

    func replaceTrailing(_ utf16Length: Int, with text: String) {
        let inserted = Array(text.utf16)
        let length = min(max(0, utf16Length), caret)
        let start = caret - length
        if let range = markedRange, NSMaxRange(range) > start {
            // The replaced text overlapped the marked range: drop the mark rather
            // than keeping a stale range.
            clearMarked()
        }
        units.replaceSubrange(start..<caret, with: inserted)
        caret = start + inserted.count
    }

    func setMarkedText(_ text: String) {
        let inserted = Array(text.utf16)
        if let range = markedRange {
            let location = range.location
            replace(range: range, with: inserted)
            if inserted.isEmpty {
                caret = location
                clearMarked()
            } else {
                markedRange = NSRange(location: location, length: inserted.count)
                caret = location + inserted.count
                markedText = text
            }
        } else {
            guard !inserted.isEmpty else {
                clearMarked()
                return
            }
            units.insert(contentsOf: inserted, at: caret)
            markedRange = NSRange(location: caret, length: inserted.count)
            caret += inserted.count
            markedText = text
        }
    }

    func commitMarkedText(with text: String) {
        let inserted = Array(text.utf16)
        if let range = markedRange {
            let location = range.location
            replace(range: range, with: inserted)
            caret = location + inserted.count
            clearMarked()
        } else {
            units.insert(contentsOf: inserted, at: caret)
            caret += inserted.count
        }
    }

    // MARK: - Host-side key processing (what the app would do with a passed key)

    /// Mirrors what the application does with a key the IME did not consume:
    /// backspace deletes the last character of the document.
    func deleteBackward() {
        guard caret > 0, caret <= units.count else { return }
        if let range = markedRange, NSMaxRange(range) > caret - 1 {
            clearMarked()
        }
        units.remove(at: caret - 1)
        caret -= 1
    }

    // MARK: - Helpers

    private func replace(range: NSRange, with inserted: [UInt16]) {
        let lower = min(max(0, range.location), units.count)
        let upper = min(units.count, lower + max(0, range.length))
        units.replaceSubrange(lower..<upper, with: inserted)
    }

    private func clearMarked() {
        markedRange = nil
        markedText = ""
    }
}
