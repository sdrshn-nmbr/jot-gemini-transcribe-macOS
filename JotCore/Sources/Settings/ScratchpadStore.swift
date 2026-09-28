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
}

public struct ScratchNote: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var updatedAt: Date

    public init(id: UUID = UUID(), text: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.text = text
        self.updatedAt = updatedAt
    }

    public var title: String {
        text.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 } ?? "New note"
    }
}

/// Notes for quick thoughts, kept as one JSON file in Application Support.
public struct ScratchpadStore: Sendable {
    public init() {}

    public static var fileURL: URL {
        FileLayout.appSupportRoot.appendingPathComponent("scratchpad.json")
    }

    public func notes() -> [ScratchNote] {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return [] }
        do {
            return try JSONDecoder().decode([ScratchNote].self, from: data)
                .sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            Log.ui.error("scratchpad: unreadable file — \(String(describing: error), privacy: .public)")
            return []
        }
    }

    public func save(_ notes: [ScratchNote], notify: Bool = true) {
        do {
            try FileManager.default.createDirectory(at: FileLayout.appSupportRoot, withIntermediateDirectories: true)
            try JSONEncoder().encode(notes).write(to: Self.fileURL, options: .atomic)
        } catch {
            Log.ui.error("scratchpad: save FAILED — \(String(describing: error), privacy: .public)")
            return
        }
        if notify { NotificationCenter.default.post(name: .gtSyncableDataChanged, object: "scratchpad") }
    }

    public func upsert(_ note: ScratchNote) {
        var all = notes()
        if let index = all.firstIndex(where: { $0.id == note.id }) {
            all[index] = note
        } else {
            all.append(note)
        }
        save(all)
    }

    public func remove(id: UUID) {
        save(notes().filter { $0.id != id })
    }
}

