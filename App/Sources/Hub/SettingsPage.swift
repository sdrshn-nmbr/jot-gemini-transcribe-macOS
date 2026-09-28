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

struct SettingsPage: View {
    @Binding var tab: SettingsTab
    let onDeleteAllHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings")
                .font(Hub.display(30, weight: .medium))
                .foregroundStyle(Hub.ink)
            HStack(spacing: 6) {
                ForEach(SettingsTab.allCases) { item in
                    Button { tab = item } label: {
                        Text(item.title)
                            .font(Hub.text(13, weight: tab == item ? .semibold : .regular))
                            .foregroundStyle(tab == item ? Hub.ink : Hub.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(tab == item ? Hub.selected : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            pane
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, -20)
        }
        .padding(.horizontal, 48)
        .padding(.top, 44)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var pane: some View {
        switch tab {
        case .general: GeneralPane()
        case .dictation: DictationPane()
        case .sync: SyncPane()
        case .privacy: PrivacyPane(onDeleteAllHistory: onDeleteAllHistory)
        case .advanced: AdvancedPane()
        case .about: AboutPane()
        }
    }
}

/// Private Cloud Sync through your iCloud Drive.
struct SyncPane: View {
    private let sync = CloudSync.shared
    @State private var enabled = CloudSync.shared.isEnabled
    @State private var history = UserDefaults.standard.bool(forKey: "historySyncEnabled")
    @State private var status = CloudSync.shared.status

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $enabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Private Cloud Sync")
                        Text("Keep your notes and preferences synced through your iCloud Drive.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!sync.isAvailable)
                .onChange(of: enabled) { _, value in
                    sync.setEnabled(value)
                    status = sync.status
                }
                Toggle(isOn: $history) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Dictation cloud storage")
                        Text("Stores your transcripts and dictation history in iCloud Drive so every Mac shows the same history. Audio stays on the Mac that recorded it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .disabled(!enabled)
                .onChange(of: history) { _, value in
                    sync.setHistoryEnabled(value)
                    status = sync.status
                }
                LabeledContent("Status", value: statusText)
                if enabled {
                    HStack {
                        Button("Sync Now") {
                            sync.syncNow()
                            status = sync.status
                        }
                        Button("Show in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([CloudSync.folder])
                        }
                    }
                }
            } footer: {
                Text("Syncs your dictionary, snippets, styles, app groups and Scratchpad notes to a Jot folder in your iCloud Drive. Nothing passes through any server except Apple's, and you can turn it off anytime.")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            guard let key = note.object as? String, key.hasPrefix("cloudSync") else { return }
            status = sync.status
        }
    }

    private var statusText: String {
        guard sync.isAvailable else { return "iCloud Drive is off on this Mac" }
        switch status {
        case .off: return "Off"
        case .unavailable: return "iCloud Drive is off on this Mac"
        case .waiting: return "Waiting for the first sync"
        case .synced(let date): return "Synced \(date.formatted(.relative(presentation: .named)))"
        case .failed(let message): return message
        }
    }
}
