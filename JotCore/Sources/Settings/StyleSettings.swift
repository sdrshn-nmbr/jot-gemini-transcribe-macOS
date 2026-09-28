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

/// Which recogniser turns audio into words.
public enum TranscriptionEngine: String, CaseIterable, Sendable {
    /// Parakeet on the Neural Engine. Audio never leaves the Mac.
    case local
    /// Gemini transcribe over the network.
    case gemini
}

/// App groups, each with its own writing style. The same four buckets Wispr
/// Flow uses, so a style chosen once covers every app of that kind.
public enum AppGroup: String, CaseIterable, Codable, Sendable {
    case work, email, personal, other

    public var title: String {
        switch self {
        case .work: return "Work messages"
        case .email: return "Email"
        case .personal: return "Personal messages"
        case .other: return "Everything else"
        }
    }
}

public enum WritingStyle: String, CaseIterable, Codable, Sendable {
    case formal, casual, veryCasual

    public var title: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    public var summary: String {
        switch self {
        case .formal: return "Caps and full punctuation"
        case .casual: return "Caps, lighter punctuation"
        case .veryCasual: return "No caps, minimal punctuation"
        }
    }
}

public extension SettingsStore {
    private static var store: UserDefaults { .standard }

    private static func write(_ value: Any?, _ key: String) {
        store.set(value, forKey: key)
        NotificationCenter.default.post(name: .gtSettingDidChange, object: key)
    }

    var transcriptionEngine: TranscriptionEngine {
        Self.store.string(forKey: "transcriptionEngine").flatMap(TranscriptionEngine.init(rawValue:)) ?? .local
    }

    func setTranscriptionEngine(_ engine: TranscriptionEngine) {
        Self.write(engine.rawValue, "transcriptionEngine")
    }

    func style(for group: AppGroup) -> WritingStyle {
        let saved = Self.store.dictionary(forKey: "writingStyles") as? [String: String]
        return saved?[group.rawValue].flatMap(WritingStyle.init(rawValue:)) ?? (group == .email ? .formal : .casual)
    }

    func setStyle(_ style: WritingStyle, for group: AppGroup) {
        var saved = Self.store.dictionary(forKey: "writingStyles") as? [String: String] ?? [:]
        saved[group.rawValue] = style.rawValue
        Self.write(saved, "writingStyles")
    }

    /// User reassignments, keyed by bundle ID. Built-in assignments fill the rest.
    var appGroupOverrides: [String: AppGroup] {
        let saved = Self.store.dictionary(forKey: "appGroupOverrides") as? [String: String] ?? [:]
        return saved.compactMapValues(AppGroup.init(rawValue:))
    }

    func setAppGroup(_ group: AppGroup?, forBundleID bundleID: String) {
        var saved = Self.store.dictionary(forKey: "appGroupOverrides") as? [String: String] ?? [:]
        saved[bundleID] = group?.rawValue
        Self.write(saved, "appGroupOverrides")
    }

    func appGroup(forBundleID bundleID: String?) -> AppGroup {
        guard let bundleID else { return .other }
        return appGroupOverrides[bundleID] ?? StyleProfiles.builtInGroups[bundleID] ?? .other
    }
}

