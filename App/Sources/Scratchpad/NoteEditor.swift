// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import AppKit
import SwiftUI

/// The scratchpad's text view: rich text with ⌘B / ⌘I / ⌘U, bullet, numbered
/// and checklist lines that continue on Return, and checkboxes you click.
final class NoteTextView: NSTextView {
    static let bullet = "• "
    static let unchecked = "☐ "
    static let checked = "☑ "

    var onEdit: (() -> Void)?

    static var bodyFont: NSFont { NSFont(name: "Figtree", size: 15) ?? .systemFont(ofSize: 15) }
    static var codeFont: NSFont { .monospacedSystemFont(ofSize: 13.5, weight: .regular) }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 6
        return [.font: bodyFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph]
    }

    func configure() {
        isRichText = true
        allowsUndo = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        drawsBackground = false
        textContainerInset = NSSize(width: 0, height: 6)
        typingAttributes = Self.baseAttributes
        insertionPointColor = .labelColor
    }

    // MARK: Loading and saving

    func load(rtf: Data?, text: String) {
        let body: NSMutableAttributedString
        if let rtf, let decoded = NSAttributedString(rtf: rtf, documentAttributes: nil) {
            body = NSMutableAttributedString(attributedString: decoded)
        } else {
            body = NSMutableAttributedString(string: text, attributes: Self.baseAttributes)
        }
        body.addAttribute(.foregroundColor, value: NSColor.labelColor, range: NSRange(location: 0, length: body.length))
        textStorage?.setAttributedString(body)
        typingAttributes = Self.baseAttributes
        undoManager?.removeAllActions()
    }

    var rtfData: Data? {
        rtf(from: NSRange(location: 0, length: string.utf16.count))
    }

    // MARK: Formatting

    enum Trait { case bold, italic }

    func toggle(_ trait: Trait) {
        let mask: NSFontTraitMask = trait == .bold ? .boldFontMask : .italicFontMask
        let manager = NSFontManager.shared
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            let font = (typingAttributes[.font] as? NSFont) ?? Self.bodyFont
            let has = manager.traits(of: font).contains(mask)
            typingAttributes[.font] = has ? manager.convert(font, toNotHaveTrait: mask) : manager.convert(font, toHaveTrait: mask)
            return
        }
        var allHave = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if let font = value as? NSFont, !manager.traits(of: font).contains(mask) { allHave = false }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { value, sub, _ in
            let font = (value as? NSFont) ?? Self.bodyFont
            let converted = allHave ? manager.convert(font, toNotHaveTrait: mask) : manager.convert(font, toHaveTrait: mask)
            storage.addAttribute(.font, value: converted, range: sub)
        }
        storage.endEditing()
        didChangeText()
    }

    func toggleUnderline() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            let on = (typingAttributes[.underlineStyle] as? Int ?? 0) != 0
            typingAttributes[.underlineStyle] = on ? 0 : NSUnderlineStyle.single.rawValue
            return
        }
        var allOn = true
        storage.enumerateAttribute(.underlineStyle, in: range) { value, _, _ in
            if (value as? Int ?? 0) == 0 { allOn = false }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.underlineStyle, value: allOn ? 0 : NSUnderlineStyle.single.rawValue, range: range)
        didChangeText()
    }

    func toggleCode() {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return }
        var allCode = true
        storage.enumerateAttribute(.font, in: range) { value, _, _ in
            if (value as? NSFont)?.isFixedPitch != true { allCode = false }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.addAttribute(.font, value: allCode ? Self.bodyFont : Self.codeFont, range: range)
        didChangeText()
    }

    enum ListKind { case bullet, numbered, checklist }

    /// Adds the marker to every selected line, or removes it when all have it.
    func toggleList(_ kind: ListKind) {
        let text = string as NSString
        let lines = text.lineRange(for: selectedRange())
        var starts: [Int] = []
        text.enumerateSubstrings(in: lines, options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            starts.append(range.location)
        }
        if starts.isEmpty { starts = [lines.location] }
        let allMarked = starts.allSatisfy { marker(at: $0) != nil && markerKind(at: $0) == kind }
        for (offset, start) in starts.enumerated().reversed() {
            if let existing = marker(at: start) {
                replace(NSRange(location: start, length: existing.utf16.count), with: "")
            }
            if !allMarked {
                let prefix: String
                switch kind {
                case .bullet: prefix = Self.bullet
                case .numbered: prefix = "\(offset + 1). "
                case .checklist: prefix = Self.unchecked
                }
                replace(NSRange(location: start, length: 0), with: prefix)
            }
        }
    }

    private func replace(_ range: NSRange, with text: String) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: text, attributes: typingAttributes))
        didChangeText()
    }

    private func marker(at lineStart: Int) -> String? {
        let rest = (string as NSString).substring(from: lineStart)
        for fixed in [Self.bullet, Self.unchecked, Self.checked] where rest.hasPrefix(fixed) { return fixed }
        if let match = rest.range(of: #"^\d+\. "#, options: .regularExpression) { return String(rest[match]) }
        return nil
    }

    private func markerKind(at lineStart: Int) -> ListKind? {
        guard let marker = marker(at: lineStart) else { return nil }
        if marker == Self.bullet { return .bullet }
        if marker == Self.unchecked || marker == Self.checked { return .checklist }
        return .numbered
    }

    // MARK: Keys and clicks

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
              window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "b": toggle(.bold); return true
        case "i": toggle(.italic); return true
        case "u": toggleUnderline(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// Return continues a list; Return on an empty list line ends it.
    override func insertNewline(_ sender: Any?) {
        let text = string as NSString
        let lineRange = text.lineRange(for: NSRange(location: selectedRange().location, length: 0))
        guard let marker = marker(at: lineRange.location) else { return super.insertNewline(sender) }
        let line = text.substring(with: lineRange).trimmingCharacters(in: .newlines)
        if line == marker.trimmingCharacters(in: .whitespaces) || line == marker {
            replace(NSRange(location: lineRange.location, length: marker.utf16.count), with: "")
            return
        }
        var next = marker
        if marker == Self.checked { next = Self.unchecked }
        if let number = Int(marker.dropLast(2)) { next = "\(number + 1). " }
        super.insertNewline(sender)
        insertText(next, replacementRange: selectedRange())
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = characterIndexForInsertion(at: point)
        let text = string as NSString
        for candidate in [index, index - 1] where candidate >= 0 && candidate < text.length {
            let character = text.substring(with: NSRange(location: candidate, length: 1))
            if character == "☐" || character == "☑" {
                let lineStart = text.lineRange(for: NSRange(location: candidate, length: 0)).location
                if candidate == lineStart {
                    replace(NSRange(location: candidate, length: 1), with: character == "☐" ? "☑" : "☐")
                    return
                }
            }
        }
        super.mouseDown(with: event)
    }

    override func didChangeText() {
        super.didChangeText()
        onEdit?()
    }
}

/// Lets SwiftUI buttons reach the live text view.
@MainActor
final class NoteEditorHandle: ObservableObject {
    weak var textView: NoteTextView?
}

struct NoteEditor: NSViewRepresentable {
    let noteID: UUID?
    let rtf: Data?
    let text: String
    let handle: NoteEditorHandle
    let onEdit: (_ text: String, _ rtf: Data?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NoteTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let old = scroll.documentView as! NSTextView
        let view = NoteTextView(frame: old.frame, textContainer: old.textContainer)
        view.autoresizingMask = old.autoresizingMask
        view.minSize = old.minSize
        view.maxSize = old.maxSize
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.configure()
        scroll.documentView = view
        handle.textView = view
        context.coordinator.loaded = noteID
        view.load(rtf: rtf, text: text)
        view.onEdit = { [weak view] in
            guard let view else { return }
            onEdit(view.string, view.rtfData)
        }
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NoteTextView else { return }
        handle.textView = view
        view.onEdit = { [weak view] in
            guard let view else { return }
            onEdit(view.string, view.rtfData)
        }
        if context.coordinator.loaded != noteID {
            context.coordinator.loaded = noteID
            view.load(rtf: rtf, text: text)
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        } else if view.string != text, view.window?.firstResponder !== view {
            view.load(rtf: rtf, text: text)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var loaded: UUID?
    }
}

