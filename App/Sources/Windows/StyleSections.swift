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

/// Engine choice and per-app-group writing styles, shown at the top of the
/// Dictation pane.
struct StyleSections: View {
    private let settings = SettingsStore()
    @State private var engine = SettingsStore().transcriptionEngine
    @State private var styles: [AppGroup: WritingStyle] = Dictionary(
        uniqueKeysWithValues: AppGroup.allCases.map { ($0, SettingsStore().style(for: $0)) }
    )
    @State private var overrides = SettingsStore().appGroupOverrides

    var body: some View {
        Section {
            Picker("Transcription", selection: $engine) {
                Text("On this Mac (Parakeet)").tag(TranscriptionEngine.local)
                Text("Gemini").tag(TranscriptionEngine.gemini)
            }
            .onChange(of: engine) { _, value in
                settings.setTranscriptionEngine(value)
                if value == .local {
                    Task.detached(priority: .utility) { _ = try? await ParakeetEngine.shared.prepare() }
                }
            }
        } footer: {
            Text(engine == .local
                 ? "Words are recognized on this Mac in well under a second, and audio never leaves it. Gemini is used only when you correct yourself or dictate punctuation or lists, and only the text is sent."
                 : "Audio is uploaded to Gemini for every dictation.")
        }

        Section {
            ForEach(AppGroup.allCases, id: \.self) { group in
                Picker(selection: binding(for: group)) {
                    ForEach(WritingStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                        Text(appNames(in: group))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
            Menu("Move an app to a group") {
                ForEach(runningApps(), id: \.bundleID) { app in
                    Menu(app.name) {
                        ForEach(AppGroup.allCases, id: \.self) { group in
                            Button(group.title) {
                                settings.setAppGroup(group, forBundleID: app.bundleID)
                                overrides = settings.appGroupOverrides
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Style")
        } footer: {
            Text(WritingStyle.allCases.map { "\($0.title): \($0.summary.lowercased())." }.joined(separator: " "))
        }
    }

    private func binding(for group: AppGroup) -> Binding<WritingStyle> {
        Binding(
            get: { styles[group] ?? .casual },
            set: { value in
                styles[group] = value
                settings.setStyle(value, for: group)
            }
        )
    }

    private func appNames(in group: AppGroup) -> String {
        let assigned = StyleProfiles.builtInGroups.merging(overrides) { _, user in user }
            .filter { $0.value == group }
            .keys
        let names = assigned.compactMap { bundleID -> String? in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }.sorted()
        if group == .other { return names.isEmpty ? "Any app not listed above" : (names + ["any other app"]).joined(separator: ", ") }
        return names.isEmpty ? "No apps" : names.joined(separator: ", ")
    }

    private struct RunningApp { let bundleID: String; let name: String }

    private func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return RunningApp(bundleID: id, name: name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

