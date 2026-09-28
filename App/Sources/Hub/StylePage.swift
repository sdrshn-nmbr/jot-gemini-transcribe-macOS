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

/// One writing style per kind of app. The previews run the same formatter
/// your dictations go through.
struct StylePage: View {
    private let settings = SettingsStore()
    private static let order: [AppGroup] = [.personal, .work, .email, .other]
    private static let samples: [AppGroup: String] = [
        .personal: "Running a few minutes late, save me a seat.",
        .work: "Deploy is done, let me know if anything looks off.",
        .email: "Thanks for sending this over, I'll review it by Friday.",
        .other: "Remind me to book the flights to Bengaluru this weekend.",
    ]

    @State private var group: AppGroup = .personal
    @State private var styles: [AppGroup: WritingStyle] = [:]
    @State private var overrides: [String: AppGroup] = [:]

    var body: some View {
        HubPage(title: "Style", subtitle: "Jot matches its formatting to the app you're dictating into.") {
            HStack(spacing: 6) {
                ForEach(Self.order, id: \.self) { item in
                    Button { group = item } label: {
                        Text(item.title)
                            .font(Hub.text(13, weight: group == item ? .semibold : .regular))
                            .foregroundStyle(group == item ? Hub.ink : Hub.secondary)
                            .padding(.horizontal, 14)
                            .frame(height: 32)
                            .background(Capsule().fill(group == item ? Hub.selected : .clear))
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(alignment: .top, spacing: 14) {
                ForEach(WritingStyle.allCases, id: \.self) { style in
                    styleCard(style)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    HubEyebrow(text: "Apps")
                    Spacer()
                    Menu {
                        ForEach(runningApps(), id: \.bundleID) { app in
                            Button(app.name) {
                                settings.setAppGroup(group, forBundleID: app.bundleID)
                                reload()
                            }
                        }
                    } label: {
                        Text("Add app").font(Hub.text(13, weight: .semibold)).foregroundStyle(Hub.ink)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                HubCard {
                    let apps = appsInGroup()
                    if apps.isEmpty {
                        Text(group == .other ? "Every app not in another group uses this style." : "No apps in this group yet.")
                            .font(Hub.text(14))
                            .foregroundStyle(Hub.secondary)
                            .padding(20)
                    } else {
                        FlowLayout(spacing: 8) {
                            ForEach(apps, id: \.bundleID) { app in
                                AppChip(name: app.name, icon: app.icon) {
                                    settings.setAppGroup(group == .other ? nil : .other, forBundleID: app.bundleID)
                                    reload()
                                }
                            }
                        }
                        .padding(16)
                    }
                }
                if group == .other, !appsInGroup().isEmpty {
                    Text("Any app not in another group also uses this style.")
                        .font(Hub.text(12))
                        .foregroundStyle(Hub.tertiary)
                }
            }
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: .gtSettingDidChange).receive(on: RunLoop.main)) { note in
            if note.object as? String == "cloudSyncApplied" { reload() }
        }
    }

    private func styleCard(_ style: WritingStyle) -> some View {
        let selected = styles[group] == style
        return Button {
            settings.setStyle(style, for: group)
            styles[group] = style
        } label: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(style.title)
                        .font(Hub.display(22, weight: .medium))
                        .foregroundStyle(Hub.ink)
                    Text(style.summary)
                        .font(Hub.text(13))
                        .foregroundStyle(Hub.secondary)
                }
                Text(StyleProfiles.format(Self.samples[group] ?? "", style: style))
                    .font(Hub.text(14))
                    .foregroundStyle(Hub.ink)
                    .lineSpacing(3)
                    .padding(12)
                    .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Hub.page))
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Hub.card))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(selected ? Hub.ink : Hub.cardEdge, lineWidth: selected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
    }

    private struct AppInfo {
        let bundleID: String
        let name: String
        let icon: NSImage?
    }

    private func appsInGroup() -> [AppInfo] {
        let assigned = StyleProfiles.builtInGroups.merging(overrides) { _, user in user }
            .filter { $0.value == group }
            .keys
        return assigned.compactMap { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            return AppInfo(bundleID: bundleID, name: name, icon: NSWorkspace.shared.icon(forFile: url.path))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func runningApps() -> [AppInfo] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let id = app.bundleIdentifier, let name = app.localizedName else { return nil }
                return AppInfo(bundleID: id, name: name, icon: app.icon)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func reload() {
        styles = Dictionary(uniqueKeysWithValues: AppGroup.allCases.map { ($0, settings.style(for: $0)) })
        overrides = settings.appGroupOverrides
    }
}

private struct AppChip: View {
    let name: String
    let icon: NSImage?
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            if let icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(name).font(Hub.text(13)).foregroundStyle(Hub.ink)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Hub.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0.35)
            .help("Remove from this group")
        }
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .frame(height: 30)
        .background(Capsule().fill(Hub.page))
        .overlay(Capsule().strokeBorder(Hub.cardEdge, lineWidth: 1))
        .onHover { hovering = $0 }
    }
}

/// Wraps chips onto as many lines as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: bounds.minY + row.y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
        }
    }

    private struct Row { var indices: [Int] = []; var y: CGFloat = 0; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                let last = rows[rows.count - 1]
                rows.append(Row(y: last.y + last.height + spacing))
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            rows[rows.count - 1] = row
        }
        return rows
    }
}
