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

/// Dictionary and Snippets share one store: a word can carry a "heard as"
/// correction, and an entry with an expansion is a snippet you trigger by
/// saying its phrase.
struct WordsPage: View {
    enum Kind { case words, snippets }
    let kind: Kind

    private let store = DictionaryStore()
    @State private var entries: [DictionaryEntry] = []
    @State private var search = ""
    @State private var editing: Draft?
    @State private var feedback: String?

    struct Draft: Identifiable {
        let id = UUID()
        var existing: UUID?
        var term = ""
        var detail = ""
    }

    var body: some View {
        HubPage(title: kind == .words ? "Dictionary" : "Snippets", subtitle: subtitle) {
            HStack(spacing: 8) {
                if kind == .words {
                    Menu {
                        Button("Import CSV…", action: importCSV)
                        Button("Export CSV…", action: exportCSV).disabled(entries.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis").foregroundStyle(Hub.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: 28)
                }
                HubPrimaryButton(title: "Add new", systemImage: "plus") { editing = Draft() }
            }
        } content: {
            HubSearchField(text: $search, prompt: kind == .words ? "Search your words" : "Search your snippets")
            if let feedback {
                Text(feedback).font(Hub.text(13)).foregroundStyle(Hub.secondary)
            }
            if filtered.isEmpty {
                emptyState
            } else {
                HubCard {
                    ForEach(Array(filtered.enumerated()), id: \.element.id) { index, entry in
                        if index > 0 { HubDivider() }
                        EntryRow(
                            entry: entry,
                            kind: kind,
                            onStar: { store.toggleStar(id: entry.id); reload() },
                            onEdit: {
                                editing = Draft(
                                    existing: entry.id,
                                    term: entry.term,
                                    detail: (kind == .words ? entry.misspelling : entry.expansion) ?? ""
                                )
                            },
                            onDelete: { store.remove(id: entry.id); reload() }
                        )
                    }
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "cloudSyncApplied" { reload() }
        }
        .sheet(item: $editing) { draft in
            EntryEditor(kind: kind, draft: draft, onCancel: { editing = nil }) { saved in
                if let problem = commit(saved) {
                    return problem
                }
                editing = nil
                return nil
            }
        }
    }

    private var subtitle: String {
        kind == .words
            ? "Names, jargon and anything Jot should always spell your way."
            : "Say a short phrase, and Jot writes the whole thing. Expansions never leave your Mac."
    }

    private var filtered: [DictionaryEntry] {
        entries
            .filter { kind == .snippets ? $0.isSnippet : !$0.isSnippet }
            .filter {
                search.isEmpty
                    || $0.term.localizedCaseInsensitiveContains(search)
                    || ($0.misspelling?.localizedCaseInsensitiveContains(search) ?? false)
                    || ($0.expansion?.localizedCaseInsensitiveContains(search) ?? false)
            }
            .sorted {
                if $0.starred != $1.starred { return $0.starred }
                return $0.createdAt > $1.createdAt
            }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(search.isEmpty ? (kind == .words ? "No words yet" : "No snippets yet") : "Nothing matches “\(search)”")
                .font(Hub.display(22))
                .foregroundStyle(Hub.ink)
            if search.isEmpty {
                Text(kind == .words
                     ? "Add a name or term once and it's spelled right in every dictation."
                     : "Try “my email address” → your address, or “my calendar link” → the link.")
                    .font(Hub.text(14))
                    .foregroundStyle(Hub.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    private func reload() {
        entries = store.entries()
    }

    /// Returns a problem to show in the editor, or nil when saved.
    private func commit(_ draft: Draft) -> String? {
        let term = draft.term.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = draft.detail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...60).contains(term.count) else { return "Keep it between 1 and 60 characters." }
        if kind == .snippets {
            guard !detail.isEmpty else { return "Add the text this phrase should write." }
            guard detail.count <= DictionaryEntry.maxExpansionLength else {
                return "Keep expansions under \(DictionaryEntry.maxExpansionLength) characters."
            }
        }
        var all = store.entries()
        if all.contains(where: { $0.id != draft.existing && $0.term.lowercased() == term.lowercased() }) {
            return "“\(term)” is already in your dictionary."
        }
        if let id = draft.existing, let index = all.firstIndex(where: { $0.id == id }) {
            all[index].term = term
            if kind == .words {
                all[index].misspelling = detail.isEmpty ? nil : detail
            } else {
                all[index].expansion = detail
            }
            store.save(all)
        } else {
            store.add(
                term: term,
                misspelling: kind == .words && !detail.isEmpty ? detail : nil,
                expansion: kind == .snippets ? detail : nil
            )
        }
        reload()
        return nil
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url,
              let csv = try? String(contentsOf: url, encoding: .utf8) else { return }
        let count = store.importCSV(csv)
        reload()
        flash(count == 0 ? "Nothing new to import." : "Imported \(count) \(count == 1 ? "entry" : "entries").")
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "jot-dictionary.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportCSV().write(to: url, atomically: true, encoding: .utf8)
            flash("Exported \(entries.count) entries.")
        } catch {
            Log.ui.error("dictionary export FAILED: \(String(describing: error), privacy: .public)")
            flash("Export failed — couldn't write the file.")
        }
    }

    private func flash(_ message: String) {
        feedback = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            feedback = nil
        }
    }
}

private struct EntryRow: View {
    let entry: DictionaryEntry
    let kind: WordsPage.Kind
    let onStar: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.term)
                        .font(Hub.text(15, weight: kind == .snippets ? .medium : .regular))
                        .foregroundStyle(Hub.ink)
                    if entry.starred {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Hub.star)
                    }
                }
                if kind == .words, let misspelling = entry.misspelling, !misspelling.isEmpty {
                    Text("Often heard as “\(misspelling)”")
                        .font(Hub.text(13))
                        .foregroundStyle(Hub.secondary)
                }
                if kind == .snippets, let expansion = entry.expansion {
                    Text(expansion)
                        .font(Hub.text(13))
                        .foregroundStyle(Hub.secondary)
                        .lineLimit(2)
                }
            }
            Spacer()
            HStack(spacing: 2) {
                if kind == .words {
                    HubIconButton(systemImage: entry.starred ? "star.fill" : "star", help: entry.starred ? "Unstar" : "Star", tint: entry.starred ? Hub.star : Hub.secondary, action: onStar)
                }
                HubIconButton(systemImage: "pencil", help: "Edit", action: onEdit)
                HubIconButton(systemImage: "trash", help: "Delete", action: onDelete)
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(hovering ? Hub.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onEdit)
    }
}

private struct EntryEditor: View {
    let kind: WordsPage.Kind
    @State var draft: WordsPage.Draft
    let onCancel: () -> Void
    let onSave: (WordsPage.Draft) -> String?
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(Hub.display(24, weight: .medium))
                .foregroundStyle(Hub.ink)
            field(kind == .words ? "Word or phrase" : "When I say") {
                TextField(kind == .words ? "Kubernetes" : "my email address", text: $draft.term)
                    .textFieldStyle(.plain)
                    .font(Hub.text(15))
            }
            if kind == .words {
                field("Often transcribed as (optional)") {
                    TextField("cooper netties", text: $draft.detail)
                        .textFieldStyle(.plain)
                        .font(Hub.text(15))
                }
            } else {
                field("Jot writes") {
                    TextEditor(text: $draft.detail)
                        .font(Hub.text(15))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 110)
                }
            }
            if let problem {
                Text(problem).font(Hub.text(13)).foregroundStyle(Hub.warn)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(Hub.text(13, weight: .medium))
                    .foregroundStyle(Hub.secondary)
                    .keyboardShortcut(.cancelAction)
                HubPrimaryButton(title: "Save") { problem = onSave(draft) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
        .background(Hub.page)
    }

    private var title: String {
        switch (kind, draft.existing == nil) {
        case (.words, true): return "Add a word"
        case (.words, false): return "Edit word"
        case (.snippets, true): return "Add a snippet"
        case (.snippets, false): return "Edit snippet"
        }
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(Hub.text(12, weight: .medium)).foregroundStyle(Hub.secondary)
            content()
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Hub.card))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Hub.cardEdge, lineWidth: 1))
        }
    }
}

