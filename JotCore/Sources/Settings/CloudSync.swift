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

/// Mirrors what you teach Jot — dictionary, snippets, writing styles, app
/// groups and scratchpad — to a Jot folder in iCloud Drive, so every Mac on
/// your Apple ID shares them. Recordings and history stay on each Mac.
///
/// One snapshot file, last writer wins. Local edits push immediately, and the
/// file is re-read when the app becomes active and once a minute, so two Macs
/// only disagree if both edit within the same minute.
public final class CloudSync: @unchecked Sendable {
    public static let shared = CloudSync()

    public static var iCloudDrive: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
    }

    public static var fileURL: URL {
        iCloudDrive.appendingPathComponent("Jot", isDirectory: true).appendingPathComponent("jot-sync.json")
    }

    struct Snapshot: Codable {
        var updatedAt: Date
        var device: String
        var dictionary: [DictionaryEntry]
        var writingStyles: [String: String]
        var appGroups: [String: String]
        var notes: [ScratchNote]
    }

    public enum Status: Equatable, Sendable {
        case off
        case unavailable
        case synced(Date)
        case failed(String)
    }

    private let defaults = UserDefaults.standard
    private let lock = NSLock()
    private var applying = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: Self.iCloudDrive.path)
    }

    public var isEnabled: Bool { defaults.bool(forKey: "cloudSyncEnabled") }

    public var status: Status {
        guard isEnabled else { return .off }
        guard isAvailable else { return .unavailable }
        if let error = defaults.string(forKey: "cloudSyncError") { return .failed(error) }
        let last = defaults.double(forKey: "cloudSyncLast")
        return last > 0 ? .synced(Date(timeIntervalSince1970: last)) : .off
    }

    public func setEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: "cloudSyncEnabled")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "cloudSyncEnabled")
        if enabled { pullThenPush() }
    }

    /// Call once at launch, on the main thread.
    public func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .gtSyncableDataChanged, object: nil, queue: .main) { [weak self] _ in
            self?.push()
        })
        observers.append(center.addObserver(forName: .gtSettingDidChange, object: nil, queue: .main) { [weak self] note in
            guard let key = note.object as? String, ["writingStyles", "appGroupOverrides"].contains(key) else { return }
            self?.push()
        })
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.pull() }
        pullThenPush()
    }

    public func pullThenPush() {
        guard isEnabled, isAvailable else { return }
        if !pull() { push() }
    }

    /// Applies the remote snapshot when it is newer than the last one this Mac
    /// wrote or applied. Returns true when something was applied.
    @discardableResult
    public func pull() -> Bool {
        guard isEnabled, isAvailable else { return false }
        let url = Self.fileURL
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        var snapshot: Snapshot?
        var readError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &readError) { readURL in
            guard let data = try? Data(contentsOf: readURL) else { return }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            snapshot = try? decoder.decode(Snapshot.self, from: data)
        }
        if let readError {
            record(error: "couldn't read iCloud Drive: \(readError.localizedDescription)")
            return false
        }
        guard let snapshot else { return false }
        let last = defaults.double(forKey: "cloudSyncLast")
        guard snapshot.updatedAt.timeIntervalSince1970 > last + 0.001 else { return false }

        lock.lock(); applying = true; lock.unlock()
        DictionaryStore().save(snapshot.dictionary)
        defaults.set(snapshot.writingStyles, forKey: "writingStyles")
        defaults.set(snapshot.appGroups, forKey: "appGroupOverrides")
        ScratchpadStore().save(snapshot.notes, notify: false)
        lock.lock(); applying = false; lock.unlock()

        defaults.set(snapshot.updatedAt.timeIntervalSince1970, forKey: "cloudSyncLast")
        defaults.removeObject(forKey: "cloudSyncError")
        Log.ui.info("cloud sync: applied snapshot from \(snapshot.device, privacy: .public)")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "cloudSyncApplied")
        return true
    }

    public func push() {
        lock.lock(); let busy = applying; lock.unlock()
        guard !busy, isEnabled, isAvailable else { return }
        let now = Date()
        let snapshot = Snapshot(
            updatedAt: now,
            device: Host.current().localizedName ?? "Mac",
            dictionary: DictionaryStore().entries(),
            writingStyles: defaults.dictionary(forKey: "writingStyles") as? [String: String] ?? [:],
            appGroups: defaults.dictionary(forKey: "appGroupOverrides") as? [String: String] ?? [:],
            notes: ScratchpadStore().notes()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else { return }
        let url = Self.fileURL
        var writeError: NSError?
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &writeError) { writeURL in
            do {
                try FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: writeURL, options: .atomic)
            } catch {
                failure = error
            }
        }
        if let problem = writeError ?? failure.map({ $0 as NSError }) {
            record(error: "couldn't write to iCloud Drive: \(problem.localizedDescription)")
            return
        }
        defaults.set(now.timeIntervalSince1970, forKey: "cloudSyncLast")
        defaults.removeObject(forKey: "cloudSyncError")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "cloudSyncPushed")
    }

    private func record(error message: String) {
        Log.ui.error("cloud sync FAILED: \(message, privacy: .public)")
        defaults.set(message, forKey: "cloudSyncError")
        NotificationCenter.default.post(name: .gtSettingDidChange, object: "cloudSyncError")
    }
}

