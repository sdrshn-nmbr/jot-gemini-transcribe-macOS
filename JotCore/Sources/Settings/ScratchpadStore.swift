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

import Foundation

public extension Notification.Name {
    /// Posted after a local edit to anything cloud sync mirrors (dictionary,
    /// snippets, scratchpad). Settings changes arrive via gtSettingDidChange.
    static let gtSyncableDataChanged = Notification.Name("com.ammaar.jot.syncable-data-changed")
    /// Posted whenever the scratchpad file changes, locally or from sync.
    static let gtScratchpadDidChange = Notification.Name("com.ammaar.jot.scratchpad-changed")
}

public struct NoteVersion: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable { case created, dictated, typed }
    public var id: UUID
    public var kind: Kind
    public var date: Date
    public var text: String
    public var rtf: Data?

    public init(kind: Kind, date: Date = Date(), text: String, rtf: Data?) {
        self.id = UUID()
        self.kind = kind
        self.date = date
        self.text = text
        self.rtf = rtf
    }
}

public struct ScratchNote: Codable, Equatable, Identifiable, Sendable {
    public static let maxVersions = 40

    public var id: UUID
    /// Plain text: titles, search, copy, send, sync conflict checks.
    public var text: String
    /// The formatted body. Nil for a note that has never been formatted.
    public var rtf: Data?
    public var pinned: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var versions: [NoteVersion]

    public init(id: UUID = UUID(), text: String = "", rtf: Data? = nil, now: Date = Date()) {
        self.id = id
        self.text = text
        self.rtf = rtf
        self.pinned = false
        self.createdAt = now
        self.updatedAt = now
        self.versions = [NoteVersion(kind: .created, date: now, text: text, rtf: rtf)]
    }

    public var title: String {
        text.split(whereSeparator: \.isNewline)
            .lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? "New note"
    }

    public var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.dropFirst().joined(separator: " ")
    }

    /// Records the body as a new version. Consecutive typed edits collapse into
    /// one version so a paragraph of typing is one entry, not hundreds.
    public mutating func record(_ kind: NoteVersion.Kind, text: String, rtf: Data?, now: Date = Date()) {
        self.text = text
        self.rtf = rtf
        updatedAt = now
        if kind == .typed, let last = versions.last, last.kind == .typed, now.timeIntervalSince(last.date) < 120 {
            versions[versions.count - 1] = NoteVersion(kind: .typed, date: now, text: text, rtf: rtf)
        } else {
            versions.append(NoteVersion(kind: kind, date: now, text: text, rtf: rtf))
        }
        if versions.count > Self.maxVersions {
            versions.removeFirst(versions.count - Self.maxVersions)
        }
    }
}

/// Notes live in one JSON file with deletion markers, so two Macs can merge
/// note by note: the newer edit of a note wins, and a delete wins over an
/// older edit.
public struct ScratchpadStore: Sendable {
    public struct Contents: Codable, Equatable, Sendable {
        public var notes: [ScratchNote] = []
        public var deleted: [UUID: Date] = [:]
        public init(notes: [ScratchNote] = [], deleted: [UUID: Date] = [:]) {
            self.notes = notes
            self.deleted = deleted
        }
    }

    public init() {}

    public static var fileURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("scratchpad.json")
    }

    public func contents() -> Contents {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return Contents() }
        do {
            return try Self.decoder.decode(Contents.self, from: data)
        } catch {
            Log.ui.error("scratchpad: unreadable file — \(String(describing: error), privacy: .public)")
            return Contents()
        }
    }

    public func notes() -> [ScratchNote] {
        contents().notes.sorted {
            if $0.pinned != $1.pinned { return $0.pinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    public func note(id: UUID) -> ScratchNote? {
        contents().notes.first { $0.id == id }
    }

    public func write(_ contents: Contents, fromSync: Bool = false) {
        do {
            try FileManager.default.createDirectory(at: FileLayout.appSupportRoot, withIntermediateDirectories: true)
            try Self.encoder.encode(contents).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.ui.error("scratchpad: save FAILED — \(String(describing: error), privacy: .public)")
            return
        }
        NotificationCenter.default.post(name: .gtScratchpadDidChange, object: nil)
        if !fromSync {
            NotificationCenter.default.post(name: .gtSyncableDataChanged, object: "scratchpad")
        }
    }

    public func upsert(_ note: ScratchNote) {
        var all = contents()
        if let index = all.notes.firstIndex(where: { $0.id == note.id }) {
            all.notes[index] = note
        } else {
            all.notes.append(note)
        }
        write(all)
    }

    public func remove(id: UUID, now: Date = Date()) {
        var all = contents()
        all.notes.removeAll { $0.id == id }
        all.deleted[id] = now
        write(all)
    }

    /// Newest edit per note wins; a deletion wins over any edit made before it.
    public static func merge(_ local: Contents, _ remote: Contents) -> Contents {
        var deleted = local.deleted
        for (id, date) in remote.deleted {
            deleted[id] = max(deleted[id] ?? .distantPast, date)
        }
        var byID: [UUID: ScratchNote] = [:]
        for note in local.notes + remote.notes {
            if let existing = byID[note.id], existing.updatedAt >= note.updatedAt { continue }
            byID[note.id] = note
        }
        let notes = byID.values.filter { note in
            guard let gone = deleted[note.id] else { return true }
            return note.updatedAt > gone
        }
        // A total order, so merging identical inputs yields identical output and
        // sync never rewrites a file that did not change.
        let ordered = notes.sorted {
            $0.createdAt != $1.createdAt ? $0.createdAt < $1.createdAt : $0.id.uuidString < $1.id.uuidString
        }
        return Contents(notes: ordered, deleted: deleted)
    }

    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}
