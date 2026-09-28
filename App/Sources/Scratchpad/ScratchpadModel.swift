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
import JotCore
import SwiftUI

enum ScratchpadOpenBehavior: String, CaseIterable, Identifiable {
    case resumeLast, newTab, lastPinned
    var id: String { rawValue }

    var title: String {
        switch self {
        case .resumeLast: return "Resume last note"
        case .newTab: return "Open in new tab"
        case .lastPinned: return "Open last active pinned note"
        }
    }

    static var current: ScratchpadOpenBehavior {
        UserDefaults.standard.string(forKey: "scratchpadOpenBehavior").flatMap(Self.init(rawValue:)) ?? .resumeLast
    }
}

/// Open tabs, the active note, the sidebar, and every action the window offers.
@MainActor
final class ScratchpadModel: ObservableObject {
    static let shared = ScratchpadModel()

    @Published private(set) var notes: [ScratchNote] = []
    @Published var tabs: [UUID] = [] { didSet { persistTabs() } }
    @Published var active: UUID? { didSet { persistTabs() } }
    @Published var sidebarOpen = UserDefaults.standard.bool(forKey: "scratchpadSidebarOpen") {
        didSet { UserDefaults.standard.set(sidebarOpen, forKey: "scratchpadSidebarOpen") }
    }
    @Published var search = ""
    @Published var toast: String?
    /// The app you were in when the scratchpad opened — where Send pastes.
    @Published private(set) var sourceApp: NSRunningApplication?

    let editor = NoteEditorHandle()
    private let store = ScratchpadStore()
    private var saveTask: Task<Void, Never>?
    private var pending: (id: UUID, text: String, rtf: Data?)?

    private init() {
        reload()
        let defaults = UserDefaults.standard
        let saved = (defaults.stringArray(forKey: "scratchpadTabs") ?? []).compactMap(UUID.init(uuidString:))
        tabs = saved.filter { id in notes.contains { $0.id == id } }
        active = defaults.string(forKey: "scratchpadActive").flatMap(UUID.init(uuidString:)).flatMap { tabs.contains($0) ? $0 : nil } ?? tabs.first
        NotificationCenter.default.addObserver(forName: .gtScratchpadDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    var activeNote: ScratchNote? { notes.first { $0.id == active } }

    var filteredNotes: [ScratchNote] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return notes }
        return notes.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    func reload() {
        notes = store.notes()
        tabs = tabs.filter { id in notes.contains { $0.id == id } }
        if let active, !tabs.contains(active) { self.active = tabs.last }
    }

    // MARK: Opening

    func prepareForOpen(behavior: ScratchpadOpenBehavior = .current) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { sourceApp = front }
        switch behavior {
        case .newTab:
            newNote()
        case .lastPinned:
            if let pinned = notes.first(where: \.pinned) { open(pinned.id) } else { resume() }
        case .resumeLast:
            resume()
        }
    }

    private func resume() {
        if let active, tabs.contains(active) { return }
        if let recent = notes.first { open(recent.id) } else { newNote() }
    }

    func open(_ id: UUID) {
        flush()
        if !tabs.contains(id) { tabs.append(id) }
        active = id
    }

    func newNote() {
        flush()
        let note = ScratchNote()
        store.upsert(note)
        reload()
        tabs.append(note.id)
        active = note.id
    }

    func close(_ id: UUID) {
        flush()
        guard let index = tabs.firstIndex(of: id) else { return }
        tabs.remove(at: index)
        if active == id { active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)] }
        discardIfEmpty(id)
    }

    /// Closing the window drops notes that were opened and never written in.
    func windowClosed() {
        flush()
        for id in tabs where id != active { discardIfEmpty(id) }
    }

    private func discardIfEmpty(_ id: UUID) {
        guard let note = notes.first(where: { $0.id == id }),
              note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !note.pinned else { return }
        store.remove(id: id)
        reload()
    }

    // MARK: Editing

    func edited(text: String, rtf: Data?) {
        guard let active else { return }
        pending = (active, text, rtf)
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func flush(kind: NoteVersion.Kind = .typed) {
        saveTask?.cancel()
        guard let pending, var note = store.note(id: pending.id) else { return }
        self.pending = nil
        guard note.text != pending.text || note.rtf != pending.rtf else { return }
        note.record(kind, text: pending.text, rtf: pending.rtf)
        store.upsert(note)
    }

    /// Dictation aimed at the scratchpad lands at the cursor directly — the
    /// app never has to paste into itself.
    func insertDictation(_ text: String) -> Bool {
        guard let view = editor.textView, view.window?.isKeyWindow == true, active != nil else { return false }
        let range = view.selectedRange()
        let before = range.location > 0 ? (view.string as NSString).substring(with: NSRange(location: range.location - 1, length: 1)) : ""
        let spaced = before.isEmpty || before == " " || before == "\n" ? text : " " + text
        view.insertText(spaced, replacementRange: range)
        flush(kind: .dictated)
        if let active, var note = store.note(id: active), note.versions.last?.kind != .dictated {
            note.record(.dictated, text: view.string, rtf: view.rtfData)
            store.upsert(note)
        }
        return true
    }

    func togglePin() {
        flush()
        guard let active, var note = store.note(id: active) else { return }
        note.pinned.toggle()
        note.updatedAt = Date()
        store.upsert(note)
    }

    func restore(_ version: NoteVersion) {
        guard let active, var note = store.note(id: active) else { return }
        note.record(.typed, text: version.text, rtf: version.rtf)
        store.upsert(note)
        editor.textView?.load(rtf: version.rtf, text: version.text)
        show("Restored")
    }

    func deleteActive() {
        guard let active else { return }
        pending = nil
        store.remove(id: active)
        reload()
        show("Note deleted")
    }

    func copyActive() {
        flush()
        guard let note = activeNote, !note.text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.text, forType: .string)
        show("Copied to clipboard")
    }

    /// Pastes the note into the app you came from.
    func send(closeWindow: @escaping () -> Void) {
        flush()
        guard let note = activeNote, !note.text.isEmpty, let app = sourceApp else { return }
        closeWindow()
        app.activate()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            _ = await PasteInserter().paste(note.text)
        }
    }

    private func show(_ message: String) {
        toast = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if self?.toast == message { self?.toast = nil }
        }
    }

    private func persistTabs() {
        UserDefaults.standard.set(tabs.map(\.uuidString), forKey: "scratchpadTabs")
        UserDefaults.standard.set(active?.uuidString, forKey: "scratchpadActive")
    }
}

