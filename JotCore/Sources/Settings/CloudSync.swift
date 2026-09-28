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

/// Private Cloud Sync through your own iCloud Drive: nothing passes through
/// any server but Apple's, and turning it off stops all writes.
///
///   Jot/preferences.json      dictionary, snippets, styles, app groups (newest wins)
///   Jot/notes.json            scratchpad, merged note by note with deletions
///   Jot/history/<mac>.json    each Mac's own transcripts (dictation cloud storage)
///
/// Each Mac only ever writes its own history file, and mirrors the others as
/// text-only history entries. Audio never leaves the Mac that recorded it.
public final class CloudSync: @unchecked Sendable {
    public static let shared = CloudSync()

    public static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    public static var folder: URL { iCloudDrive.appendingPathComponent("Jot", isDirectory: true) }
    static var preferencesURL: URL { folder.appendingPathComponent("preferences.json") }
    static var notesURL: URL { folder.appendingPathComponent("notes.json") }
    static var historyFolder: URL { folder.appendingPathComponent("history", isDirectory: true) }
    static let syncedMarker = "synced-from"

    struct Preferences: Codable {
        var updatedAt: Date
        var device: String
        var dictionary: [DictionaryEntry]
        var writingStyles: [String: String]
        var appGroups: [String: String]
    }

    struct SyncedDictation: Codable {
        var id: UUID
        var startedAt: Date
        var status: String
        var targetAppName: String?
        var targetAppBundleID: String?
        var durationSeconds: Double?
        var rawTranscript: String?
        var cleanedTranscript: String?
    }

    public enum Status: Equatable, Sendable {
        case off
        case unavailable
        case waiting
        case synced(Date)
        case failed(String)
    }

    private let defaults = UserDefaults.standard
    private var applying = false
    private var timer: Timer?
    private var historyPush: DispatchWorkItem?
    private var history: HistoryStore?

    public var isAvailable: Bool { FileManager.default.fileExists(atPath: Self.iCloudDrive.path) }
    public var isEnabled: Bool { defaults.bool(forKey: "cloudSyncEnabled") }
    public var historyEnabled: Bool { isEnabled && defaults.bool(forKey: "historySyncEnabled") }

    public var deviceID: String {
        if let id = defaults.string(forKey: "syncDeviceID") { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: "syncDeviceID")
        return id
    }

    public var status: Status {
        guard isEnabled else { return .off }
        guard isAvailable else { return .unavailable }
        if let error = defaults.string(forKey: "cloudSyncError") { return .failed(error) }
        let last = defaults.double(forKey: "cloudSyncLastActivity")
        return last > 0 ? .synced(Date(timeIntervalSince1970: last)) : .waiting
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "cloudSyncEnabled")
        changed("cloudSyncEnabled")
        if enabled { syncNow() }
    }

    public func setHistoryEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "historySyncEnabled")
        changed("historySyncEnabled")
        if enabled { syncNow() } else { removeMirroredHistory() }
    }

    /// Call once at launch, on the main thread.
    public func start(history: HistoryStore?) {
        self.history = history
        let center = NotificationCenter.default
        center.addObserver(forName: .gtSyncableDataChanged, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.applying else { return }
            if note.object as? String == "scratchpad" { self.syncNotes() } else { self.pushPreferences() }
        }
        center.addObserver(forName: .gtSettingDidChange, object: nil, queue: .main) { [weak self] note in
            guard let self, !self.applying, let key = note.object as? String,
                  ["writingStyles", "appGroupOverrides"].contains(key) else { return }
            self.pushPreferences()
        }
        center.addObserver(forName: .gtHistoryDidChange, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleHistoryPush()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pullAll() }
        syncNow()
    }

    public func syncNow() {
        guard isEnabled, isAvailable else { return }
        if !pullPreferences() { pushPreferences() }
        syncNotes()
        if historyEnabled {
            pushHistory()
            pullHistory()
        }
    }

    private func pullAll() {
        guard isEnabled, isAvailable else { return }
        pullPreferences()
        syncNotes()
        if historyEnabled { pullHistory() }
    }

    // MARK: Preferences (newest wins)

    @discardableResult
    private func pullPreferences() -> Bool {
        guard let remote: Preferences = read(Self.preferencesURL) else { return false }
        guard remote.updatedAt.timeIntervalSince1970 > defaults.double(forKey: "cloudSyncPreferencesAt") + 0.001 else { return false }
        applying = true
        DictionaryStore().save(remote.dictionary)
        defaults.set(remote.writingStyles, forKey: "writingStyles")
        defaults.set(remote.appGroups, forKey: "appGroupOverrides")
        applying = false
        defaults.set(remote.updatedAt.timeIntervalSince1970, forKey: "cloudSyncPreferencesAt")
        Log.ui.info("cloud sync: preferences from \(remote.device, privacy: .public)")
        changed("cloudSyncApplied")
        touch()
        return true
    }

    private func pushPreferences() {
        guard isEnabled, isAvailable else { return }
        let now = Date()
        let prefs = Preferences(
            updatedAt: now,
            device: Host.current().localizedName ?? "Mac",
            dictionary: DictionaryStore().entries(),
            writingStyles: defaults.dictionary(forKey: "writingStyles") as? [String: String] ?? [:],
            appGroups: defaults.dictionary(forKey: "appGroupOverrides") as? [String: String] ?? [:]
        )
        if write(prefs, to: Self.preferencesURL) {
            defaults.set(now.timeIntervalSince1970, forKey: "cloudSyncPreferencesAt")
            touch()
        }
    }

    // MARK: Notes (merged)

    private func syncNotes() {
        guard isEnabled, isAvailable else { return }
        let store = ScratchpadStore()
        let local = store.contents()
        let remote: ScratchpadStore.Contents = read(Self.notesURL) ?? ScratchpadStore.Contents()
        let merged = ScratchpadStore.merge(local, remote)
        if merged != local {
            applying = true
            store.write(merged, fromSync: true)
            applying = false
        }
        if merged != remote, write(merged, to: Self.notesURL) {
            touch()
        } else if merged != local {
            touch()
        }
    }

    // MARK: History (dictation cloud storage)

    private func scheduleHistoryPush() {
        guard historyEnabled else { return }
        historyPush?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pushHistory() }
        historyPush = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func pushHistory() {
        guard historyEnabled, let history else { return }
        let own = history.records(limit: 5_000).filter { record in
            !record.displayText.isEmpty && !Self.isMirrored(record.folderURL)
        }
        let payload = own.compactMap { record -> SyncedDictation? in
            guard let id = UUID(uuidString: record.id) else { return nil }
            return SyncedDictation(
                id: id, startedAt: record.startedAt, status: record.status,
                targetAppName: record.targetAppName, targetAppBundleID: record.targetAppBundleID,
                durationSeconds: record.durationSeconds,
                rawTranscript: record.rawTranscript, cleanedTranscript: record.cleanedTranscript
            )
        }
        if write(payload, to: Self.historyFolder.appendingPathComponent("\(deviceID).json")) { touch() }
    }

    private func pullHistory() {
        guard historyEnabled, let history else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: Self.historyFolder, includingPropertiesForKeys: nil)) ?? []
        var mirrored = defaults.dictionary(forKey: "syncedHistory") as? [String: String] ?? [:]
        var dismissed = Set(defaults.stringArray(forKey: "syncedHistoryDismissed") ?? [])
        var imported = 0
        var removed = 0
        var devices: Set<String> = []
        for file in files where file.pathExtension == "json" || file.lastPathComponent.hasSuffix(".json.icloud") {
            let device = file.lastPathComponent.replacingOccurrences(of: ".icloud", with: "")
                .replacingOccurrences(of: ".json", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard device != deviceID else { continue }
            devices.insert(device)
            guard let entries: [SyncedDictation] = read(Self.historyFolder.appendingPathComponent("\(device).json")) else { continue }
            let ids = Set(entries.map(\.id.uuidString))
            for entry in entries where mirrored[entry.id.uuidString] == nil && !dismissed.contains(entry.id.uuidString) {
                guard materialize(entry, from: device, into: history) else { continue }
                mirrored[entry.id.uuidString] = device
                imported += 1
            }
            for (id, source) in mirrored where source == device && !ids.contains(id) {
                history.delete(id: id, removeFolder: true)
                mirrored[id] = nil
                removed += 1
            }
        }
        // A Mac that stopped sharing its history takes its entries with it.
        for (id, source) in mirrored where !devices.contains(source) {
            history.delete(id: id, removeFolder: true)
            mirrored[id] = nil
            removed += 1
        }
        // A mirrored entry you deleted here stays deleted.
        let present = Set(history.records(limit: 20_000).map(\.id))
        for (id, _) in mirrored where !present.contains(id) {
            dismissed.insert(id)
            mirrored[id] = nil
        }
        defaults.set(mirrored, forKey: "syncedHistory")
        defaults.set(Array(dismissed), forKey: "syncedHistoryDismissed")
        if imported + removed > 0 {
            Log.ui.info("cloud sync: history +\(imported) −\(removed) from other Macs")
            touch()
        }
    }

    private func materialize(_ entry: SyncedDictation, from device: String, into history: HistoryStore) -> Bool {
        do {
            let folder = try FileLayout.makeSessionFolder(id: entry.id, now: entry.startedAt)
            var meta = SessionMeta(id: entry.id, startedAt: entry.startedAt, status: SessionMeta.Status(rawValue: entry.status) ?? .inserted)
            meta.targetAppName = entry.targetAppName
            meta.targetAppBundleID = entry.targetAppBundleID
            meta.audioDurationSeconds = entry.durationSeconds
            meta.rawTranscript = entry.rawTranscript
            meta.cleanedTranscript = entry.cleanedTranscript
            meta.write(to: folder)
            try device.write(to: folder.appendingPathComponent(Self.syncedMarker), atomically: true, encoding: .utf8)
            history.upsert(meta: meta, folder: folder)
            return true
        } catch {
            Log.ui.error("cloud sync: couldn't add a synced dictation — \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func removeMirroredHistory() {
        guard let history else { return }
        let mirrored = defaults.dictionary(forKey: "syncedHistory") as? [String: String] ?? [:]
        for id in mirrored.keys { history.delete(id: id, removeFolder: true) }
        defaults.removeObject(forKey: "syncedHistory")
    }

    static func isMirrored(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(syncedMarker).path)
    }

    // MARK: File I/O

    private func read<T: Decodable>(_ url: URL) -> T? {
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var result: T?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            do {
                result = try JSONDecoder().decode(T.self, from: data)
            } catch {
                Log.ui.error("cloud sync: unreadable \(url.lastPathComponent, privacy: .public) — \(String(describing: error), privacy: .public)")
            }
        }
        if let coordinationError { fail("couldn't read iCloud Drive: \(coordinationError.localizedDescription)") }
        return result
    }

    private func write<T: Encodable>(_ value: T, to url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(value) else { return false }
        var coordinationError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { writeURL in
            do {
                try FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: writeURL, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let problem = coordinationError ?? failure.map({ $0 as NSError }) {
            fail("couldn't write to iCloud Drive: \(problem.localizedDescription)")
            return false
        }
        return true
    }

    private func touch() {
        defaults.set(Date().timeIntervalSince1970, forKey: "cloudSyncLastActivity")
        defaults.removeObject(forKey: "cloudSyncError")
        changed("cloudSyncActivity")
    }

    private func fail(_ message: String) {
        Log.ui.error("cloud sync FAILED: \(message, privacy: .public)")
        defaults.set(message, forKey: "cloudSyncError")
        changed("cloudSyncError")
    }

    private func changed(_ key: String) {
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }
}
