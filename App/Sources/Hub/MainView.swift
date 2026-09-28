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

enum MainSection: String, CaseIterable, Identifiable {
    case home, dictionary, snippets, style, scratchpad, settings
    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Dictation"
        case .dictionary: return "Dictionary"
        case .snippets: return "Snippets"
        case .style: return "Style"
        case .scratchpad: return "Scratchpad"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .home: return "mic"
        case .dictionary: return "book.closed"
        case .snippets: return "scissors"
        case .style: return "textformat"
        case .scratchpad: return "square.and.pencil"
        case .settings: return "gearshape"
        }
    }

    static let primary: [MainSection] = [.home, .dictionary, .snippets, .style, .scratchpad]
}

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, dictation, sync, privacy, advanced, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .dictation: return "Dictation"
        case .sync: return "Sync"
        case .privacy: return "Privacy"
        case .advanced: return "Advanced"
        case .about: return "About"
        }
    }
}

@MainActor
final class MainWindowModel: ObservableObject {
    @Published var selection: MainSection = .home
    @Published var settingsTab: SettingsTab = .general
}

struct MainView: View {
    @ObservedObject var model: MainWindowModel
    let store: HistoryStore?
    let onRetry: (DictationRecord) -> Void
    let onDeleteAllHistory: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
                .background(RoundedRectangle(cornerRadius: 18).fill(Hub.page))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Hub.pageEdge, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .padding(.top, 10)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
        }
        .background(Hub.chrome)
        .frame(minWidth: 980, minHeight: 640)
        .tint(Hub.ink)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                JotLogo(height: 18)
                Text("Jot")
                    .font(Hub.text(22, weight: .semibold))
                    .foregroundStyle(Hub.ink)
            }
            .padding(.leading, 12)
            .padding(.top, 44)
            .padding(.bottom, 22)

            ForEach(MainSection.primary) { section in
                SidebarRow(title: section.title, icon: section.icon, selected: model.selection == section) {
                    model.selection = section
                }
            }
            Spacer()
            Rectangle().fill(Hub.cardEdge).frame(height: 1).padding(.horizontal, 8).padding(.bottom, 8)
            SidebarRow(title: "Settings", icon: "gearshape", selected: model.selection == .settings) {
                model.selection = .settings
            }
            SidebarRow(title: "Help", icon: "questionmark.circle", selected: false) {
                NSWorkspace.shared.open(URL(string: "https://github.com/sdrshn-nmbr/jot-gemini-transcribe-macOS")!)
            }
            .padding(.bottom, 14)
        }
        .padding(.horizontal, 10)
        .frame(width: 228)
    }

    @ViewBuilder
    private var page: some View {
        switch model.selection {
        case .home:
            HomePage(store: store, onRetry: onRetry)
        case .dictionary:
            WordsPage(kind: .words)
        case .snippets:
            WordsPage(kind: .snippets)
        case .style:
            StylePage()
        case .scratchpad:
            ScratchpadPage()
        case .settings:
            SettingsPage(tab: $model.settingsTab, onDeleteAllHistory: onDeleteAllHistory)
        }
    }
}

private struct SidebarRow: View {
    let title: String
    let icon: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .regular))
                    .frame(width: 20)
                Text(title)
                    .font(Hub.text(15, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Hub.ink)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(selected ? Hub.selected : hovering ? Hub.hover : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

