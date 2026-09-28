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

/// Quick notes you can dictate straight into. Saved as you type.
struct ScratchpadPage: View {
    private let store = ScratchpadStore()
    @State private var notes: [ScratchNote] = []
    @State private var selection: UUID?
    @State private var text = ""
    @State private var saveTask: Task<Void, Never>?
    @FocusState private var editorFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            list
                .frame(width: 260)
            Rectangle().fill(Hub.cardEdge).frame(width: 1)
            editor
        }
        .onAppear {
            reload()
            if selection == nil { select(notes.first) }
        }
        .onDisappear { flush() }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            guard note.object as? String == "cloudSyncApplied" else { return }
            reload()
            if let id = selection, let fresh = notes.first(where: { $0.id == id }) { text = fresh.text }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Scratchpad")
                    .font(Hub.display(26, weight: .medium))
                    .foregroundStyle(Hub.ink)
                Spacer()
                HubIconButton(systemImage: "square.and.pencil", help: "New note", tint: Hub.ink, action: newNote)
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.top, 40)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(notes) { note in
                        NoteRow(note: note, selected: note.id == selection) {
                            flush()
                            select(note)
                        } onDelete: {
                            delete(note)
                        }
                    }
                }
            }
            if notes.isEmpty {
                Text("Quick thoughts, to-dos, a message you're polishing before you send it.")
                    .font(Hub.text(13))
                    .foregroundStyle(Hub.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }

    @ViewBuilder
    private var editor: some View {
        if selection == nil {
            VStack(spacing: 14) {
                Text("Nothing open")
                    .font(Hub.display(24))
                    .foregroundStyle(Hub.ink)
                HubPrimaryButton(title: "Start a note", systemImage: "plus", action: newNote)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if let note = notes.first(where: { $0.id == selection }) {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(Hub.text(12))
                        .foregroundStyle(Hub.tertiary)
                }
                TextEditor(text: $text)
                    .font(Hub.text(16))
                    .foregroundStyle(Hub.ink)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($editorFocused)
                    .onChange(of: text) { _, _ in scheduleSave() }
            }
            .padding(.horizontal, 40)
            .padding(.top, 44)
            .padding(.bottom, 24)
        }
    }

    private func reload() {
        notes = store.notes()
    }

    private func select(_ note: ScratchNote?) {
        selection = note?.id
        text = note?.text ?? ""
    }

    private func newNote() {
        flush()
        let note = ScratchNote()
        store.upsert(note)
        reload()
        select(note)
        editorFocused = true
    }

    private func delete(_ note: ScratchNote) {
        store.remove(id: note.id)
        reload()
        if selection == note.id { select(notes.first) }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    private func flush() {
        saveTask?.cancel()
        guard let id = selection, let current = notes.first(where: { $0.id == id }), current.text != text else { return }
        store.upsert(ScratchNote(id: id, text: text, updatedAt: Date()))
        reload()
    }
}

private struct NoteRow: View {
    let note: ScratchNote
    let selected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                Text(note.title)
                    .font(Hub.text(14, weight: .medium))
                    .foregroundStyle(Hub.ink)
                    .lineLimit(1)
                Text(note.updatedAt.formatted(.relative(presentation: .named)))
                    .font(Hub.text(12))
                    .foregroundStyle(Hub.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? Hub.selected : hovering ? Hub.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Delete Note", role: .destructive, action: onDelete)
        }
    }
}

