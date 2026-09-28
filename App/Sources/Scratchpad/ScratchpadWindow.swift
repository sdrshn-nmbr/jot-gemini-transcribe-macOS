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

/// A panel that takes typing without taking focus from the app underneath,
/// the way Spotlight does — so Send and dictation still know where you were.
final class ScratchpadPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// The floating scratchpad: opens over whatever you're doing with ⌥S, keeps
/// your tabs, and goes away with Esc or ⌥S again.
@MainActor
final class ScratchpadWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ScratchpadWindowController()
    private let hotKey = GlobalHotKey(id: 1)

    private init() {
        let window = ScratchpadPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isFloatingPanel = true
        window.hidesOnDeactivate = false
        window.becomesKeyOnlyIfNeeded = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Scratchpad"
        window.level = .floating
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 420, height: 320)
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: ScratchpadView(model: .shared, close: { [weak self] in self?.close() }, resize: { [weak self] in self?.toggleSize() }))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    static var combo: GlobalHotKey.Combo {
        if let data = UserDefaults.standard.data(forKey: "scratchpadHotKey"),
           let combo = try? JSONDecoder().decode(GlobalHotKey.Combo.self, from: data) { return combo }
        return .openScratchpad
    }

    static func setCombo(_ combo: GlobalHotKey.Combo) {
        UserDefaults.standard.set(try? JSONEncoder().encode(combo), forKey: "scratchpadHotKey")
        shared.registerHotKey()
    }

    func registerHotKey() {
        hotKey.register(Self.combo) { [weak self] in self?.toggle() }
    }

    func toggle() {
        if window?.isVisible == true, window?.isKeyWindow == true {
            close()
        } else {
            open()
        }
    }

    func open(note: UUID? = nil) {
        ScratchpadModel.shared.prepareForOpen()
        if let note { ScratchpadModel.shared.open(note) }
        guard let window else { return }
        if !window.isVisible { place(window) }
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Centered a little above middle on the screen you're working on.
    private func place(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2 + area.height * 0.08))
    }

    func newNote() {
        open()
        ScratchpadModel.shared.newNote()
    }

    override func close() {
        ScratchpadModel.shared.windowClosed()
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        ScratchpadModel.shared.windowClosed()
    }

    private func toggleSize() {
        guard let window else { return }
        let compact = window.frame.width < 700
        let size = compact ? NSSize(width: 860, height: 640) : NSSize(width: 560, height: 520)
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true, animate: true)
    }
}

struct ScratchpadView: View {
    @ObservedObject var model: ScratchpadModel
    let close: () -> Void
    let resize: () -> Void
    @State private var versionsShown = false
    @State private var formatShown = false

    var body: some View {
        HStack(spacing: 0) {
            if model.sidebarOpen {
                sidebar.frame(width: 220)
                Rectangle().fill(Hub.cardEdge).frame(width: 1)
            }
            VStack(spacing: 0) {
                tabBar
                if let note = model.activeNote {
                    NoteEditor(noteID: note.id, rtf: note.rtf, text: note.text, handle: model.editor) { text, rtf in
                        model.edited(text: text, rtf: rtf)
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 6)
                    bottomBar(note)
                } else {
                    emptyState
                }
            }
        }
        .background(Hub.page)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(Hub.text(12, weight: .medium))
                    .foregroundStyle(Hub.buttonText)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(Hub.button))
                    .padding(.bottom, 56)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .animation(.easeOut(duration: 0.18), value: model.sidebarOpen)
        .background(shortcuts)
        .onExitCommand(perform: close)
    }

    // MARK: Tabs

    private var tabBar: some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: model.sidebarOpen ? 8 : 70, height: 1)
            HubIconButton(systemImage: "sidebar.left", help: model.sidebarOpen ? "Collapse Notes" : "Show Notes") {
                model.sidebarOpen.toggle()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(model.tabs, id: \.self) { id in
                        TabChip(
                            title: model.notes.first { $0.id == id }?.title ?? "New note",
                            pinned: model.notes.first { $0.id == id }?.pinned ?? false,
                            active: model.active == id,
                            select: { model.open(id) },
                            close: { model.close(id) }
                        )
                    }
                }
            }
            HubIconButton(systemImage: "plus", help: "New tab (⌘T)") { model.newNote() }
            Spacer(minLength: 4)
            HubIconButton(systemImage: "arrow.up.left.and.arrow.down.right", help: "Expand window", action: resize)
        }
        .padding(.trailing, 10)
        .frame(height: 44)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Color.clear.frame(height: 30)
            HubSearchField(text: $model.search, prompt: "Search notes…")
            HubEyebrow(text: "Recents")
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(model.filteredNotes) { note in
                        Button { model.open(note.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    if note.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(Hub.secondary) }
                                    Text(note.title).font(Hub.text(13, weight: .medium)).foregroundStyle(Hub.ink).lineLimit(1)
                                }
                                Text(note.updatedAt.formatted(.relative(presentation: .named)))
                                    .font(Hub.text(11)).foregroundStyle(Hub.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 8).fill(model.active == note.id ? Hub.selected : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if model.filteredNotes.isEmpty {
                        Text(model.search.isEmpty ? "No notes yet" : "No matching notes")
                            .font(Hub.text(12)).foregroundStyle(Hub.secondary)
                            .padding(.top, 8)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .background(Hub.chrome)
    }

    // MARK: Bottom bar

    private func bottomBar(_ note: ScratchNote) -> some View {
        HStack(spacing: 2) {
            Text("\(SettingsStore().hotkeyKey.displayName) to dictate")
                .font(Hub.text(12))
                .foregroundStyle(Hub.tertiary)
                .padding(.leading, 6)
            Spacer()
            HubIconButton(systemImage: "textformat", help: "Formatting") { formatShown.toggle() }
                .popover(isPresented: $formatShown, arrowEdge: .top) { formatting }
            HubIconButton(systemImage: note.pinned ? "pin.fill" : "pin", help: note.pinned ? "Unpin" : "Pin") { model.togglePin() }
            HubIconButton(systemImage: "clock.arrow.circlepath", help: "Version history") { versionsShown.toggle() }
                .popover(isPresented: $versionsShown, arrowEdge: .top) { versions(note) }
            HubIconButton(systemImage: "doc.on.doc", help: "Copy") { model.copyActive() }
            HubIconButton(systemImage: "trash", help: "Delete note") { model.deleteActive() }
            if let app = model.sourceApp, let name = app.localizedName {
                Button { model.send(closeWindow: close) } label: {
                    Text("Send in \(name)")
                        .font(Hub.text(12, weight: .semibold))
                        .foregroundStyle(Hub.buttonText)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(Capsule().fill(Hub.button))
                }
                .buttonStyle(.plain)
                .disabled(note.text.isEmpty)
                .padding(.leading, 6)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 48)
        .overlay(alignment: .top) { Rectangle().fill(Hub.cardEdge).frame(height: 1) }
    }

    private var formatting: some View {
        HStack(spacing: 2) {
            format("bold", "Bold (⌘B)") { $0.toggle(.bold) }
            format("italic", "Italic (⌘I)") { $0.toggle(.italic) }
            format("underline", "Underline (⌘U)") { $0.toggleUnderline() }
            format("chevron.left.forwardslash.chevron.right", "Inline code") { $0.toggleCode() }
            Rectangle().fill(Hub.cardEdge).frame(width: 1, height: 18).padding(.horizontal, 4)
            format("list.bullet", "Bullet list") { $0.toggleList(.bullet) }
            format("list.number", "Numbered list") { $0.toggleList(.numbered) }
            format("checklist", "Checklist") { $0.toggleList(.checklist) }
        }
        .padding(8)
    }

    private func format(_ icon: String, _ help: String, _ apply: @escaping (NoteTextView) -> Void) -> some View {
        HubIconButton(systemImage: icon, help: help, tint: Hub.ink) {
            guard let view = model.editor.textView else { return }
            apply(view)
            view.window?.makeFirstResponder(view)
        }
    }

    private func versions(_ note: ScratchNote) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Version history").font(Hub.text(13, weight: .semibold)).foregroundStyle(Hub.ink)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(note.versions.reversed()) { version in
                        Button {
                            model.restore(version)
                            versionsShown = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(label(version.kind)).font(Hub.text(12, weight: .medium)).foregroundStyle(Hub.ink)
                                    Spacer()
                                    Text(version.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(Hub.text(11)).foregroundStyle(Hub.secondary)
                                }
                                Text(version.text.isEmpty ? "Empty" : String(version.text.prefix(90)))
                                    .font(Hub.text(12)).foregroundStyle(Hub.secondary).lineLimit(2)
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func label(_ kind: NoteVersion.Kind) -> String {
        switch kind {
        case .created: return "Created"
        case .dictated: return "Dictated"
        case .typed: return "Typed edits"
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text("For quick thoughts you want to come back to")
                .font(Hub.display(20))
                .foregroundStyle(Hub.ink)
            HubPrimaryButton(title: "Start new note", systemImage: "plus") { model.newNote() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Hidden buttons carry the window's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.newNote() }.keyboardShortcut("t", modifiers: .command)
            Button("") { model.newNote() }.keyboardShortcut("n", modifiers: .command)
            Button("") { if let active = model.active { model.close(active) } }.keyboardShortcut("w", modifiers: .command)
            Button("") { model.sidebarOpen.toggle() }.keyboardShortcut("s", modifiers: [.command, .shift])
            Button("") { model.send(closeWindow: close) }.keyboardShortcut(.return, modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

private struct TabChip: View {
    let title: String
    let pinned: Bool
    let active: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if pinned { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(Hub.secondary) }
            Text(title)
                .font(Hub.text(12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Hub.ink : Hub.secondary)
                .lineLimit(1)
                .frame(maxWidth: 140, alignment: .leading)
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(Hub.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering || active ? 1 : 0)
            .accessibilityLabel("Close tab \(title)")
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 8).fill(active ? Hub.selected : hovering ? Hub.hover : .clear))
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
    }
}
