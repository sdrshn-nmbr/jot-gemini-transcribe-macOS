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

/// The Scratchpad page of the main window: what it is, how to open it, and
/// your recent notes. Notes open in the floating scratchpad.
struct ScratchpadPage: View {
    @ObservedObject private var model = ScratchpadModel.shared
    @State private var behavior = ScratchpadOpenBehavior.current
    @State private var combo = ScratchpadWindowController.combo
    @State private var recording = false
    @State private var monitor: Any?
    @State private var searching = false

    var body: some View {
        HubPage(title: "Scratchpad") {
            HubPrimaryButton(title: "New note", systemImage: "plus") { ScratchpadWindowController.shared.newNote() }
        } content: {
            banner
            HubCard {
                row(title: "Open Scratchpad", detail: "Open the scratchpad window from anywhere") {
                    Button(action: toggleRecording) {
                        Text(recording ? "Press keys…" : combo.display)
                            .font(Hub.text(13, weight: .semibold))
                            .foregroundStyle(Hub.ink)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Hub.page))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(recording ? Hub.ink : Hub.cardEdge, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Click, then press the new shortcut")
                }
                HubDivider()
                row(title: "Scratchpad open behavior", detail: "Choose what happens when you open the scratchpad") {
                    Picker("", selection: $behavior) {
                        ForEach(ScratchpadOpenBehavior.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .onChange(of: behavior) { _, value in
                        UserDefaults.standard.set(value.rawValue, forKey: "scratchpadOpenBehavior")
                    }
                }
            }

            HStack {
                HubEyebrow(text: "Recents")
                Spacer()
                HubIconButton(systemImage: searching ? "xmark" : "magnifyingglass", help: searching ? "Close search" : "Search your notes") {
                    searching.toggle()
                    if !searching { model.search = "" }
                }
            }
            if searching {
                HubSearchField(text: $model.search, prompt: "Search notes…")
            }
            if model.filteredNotes.isEmpty {
                Text(model.search.isEmpty ? "No notes found" : "No matching notes")
                    .font(Hub.text(14))
                    .foregroundStyle(Hub.secondary)
            } else {
                HubCard {
                    ForEach(Array(model.filteredNotes.enumerated()), id: \.element.id) { index, note in
                        if index > 0 { HubDivider() }
                        NoteListRow(note: note) { ScratchpadWindowController.shared.open(note: note.id) }
                    }
                }
            }
        }
        .onDisappear(perform: stopRecording)
    }

    private var banner: some View {
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text("For quick thoughts you want to come back to")
                    .font(Hub.display(26))
                    .foregroundStyle(Color(white: 0.98))
                Text("Drop a to-do list, polish a message before you send it, brain dump an idea. Scratchpad is your safe space to save, create, and explore.")
                    .font(Hub.text(14))
                    .foregroundStyle(Color(white: 0.85))
                    .fixedSize(horizontal: false, vertical: true)
                Button { ScratchpadWindowController.shared.newNote() } label: {
                    Text("Start new note")
                        .font(Hub.text(13, weight: .semibold))
                        .foregroundStyle(Color(white: 0.1))
                        .padding(.horizontal, 16)
                        .frame(height: 34)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color(white: 0.97)))
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .background(
            LinearGradient(
                colors: [Color(red: 0.16, green: 0.13, blue: 0.11), Color(red: 0.36, green: 0.27, blue: 0.2), Color(red: 0.52, green: 0.44, blue: 0.36)],
                startPoint: .leading, endPoint: .trailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func row<Control: View>(title: String, detail: String, @ViewBuilder control: () -> Control) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Hub.text(14, weight: .medium)).foregroundStyle(Hub.ink)
                Text(detail).font(Hub.text(12)).foregroundStyle(Hub.secondary)
            }
            Spacer()
            control()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private func toggleRecording() {
        if recording { return stopRecording() }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            guard let new = GlobalHotKey.Combo(event: event) else { return nil }
            ScratchpadWindowController.setCombo(new)
            combo = new
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

private struct NoteListRow: View {
    let note: ScratchNote
    let open: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if note.pinned { Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(Hub.secondary) }
                        Text(note.title).font(Hub.text(15, weight: .medium)).foregroundStyle(Hub.ink).lineLimit(1)
                    }
                    if !note.preview.isEmpty {
                        Text(note.preview).font(Hub.text(13)).foregroundStyle(Hub.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Text(note.updatedAt.formatted(.relative(presentation: .named)))
                    .font(Hub.text(12)).foregroundStyle(Hub.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(hovering ? Hub.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

