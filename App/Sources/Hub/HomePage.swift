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

/// Every dictation, newest first, grouped by day, with lifetime numbers
/// alongside. Rows expand in place; the detail sheet has audio, raw text,
/// retry and delete.
struct HomePage: View {
    let store: HistoryStore?
    let onRetry: (DictationRecord) -> Void

    @State private var records: [DictationRecord] = []
    @State private var stats = HistoryStore.Stats(totalWords: 0, totalDictations: 0, averageWPM: 0)
    @State private var streak = 0
    @State private var query = ""
    @State private var searching = false
    @State private var detail: DictationRecord?

    var body: some View {
        HubPage(title: "Welcome back, \(firstName)") {
            HStack(alignment: .top, spacing: 28) {
                VStack(alignment: .leading, spacing: 28) {
                    if !attention.isEmpty { attentionShelf }
                    if searching {
                        HubSearchField(text: $query, prompt: "Search everything you've dictated")
                            .onChange(of: query) { _, _ in reload() }
                    }
                    if timeline.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    HubEyebrow(text: group.day)
                                    Spacer()
                                    if index == 0 {
                                        HubIconButton(systemImage: searching ? "xmark" : "magnifyingglass", help: searching ? "Close search" : "Search") {
                                            searching.toggle()
                                            if !searching { query = ""; reload() }
                                        }
                                    }
                                }
                                HubCard {
                                    ForEach(Array(group.items.enumerated()), id: \.element.id) { rowIndex, record in
                                        if rowIndex > 0 { HubDivider() }
                                        LogRow(record: record, onOpen: { detail = record }, onRetry: { onRetry(record) }, onDelete: { delete(record) })
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statsCard
                    .frame(width: 250)
            }
        }
        .onAppear(perform: reload)
        .onReceive(
            NotificationCenter.default.publisher(for: .gtHistoryDidChange)
                .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
        ) { _ in reload() }
        .sheet(item: $detail) { record in
            RecordDetailSheet(
                record: record,
                onRetry: { onRetry(record) },
                onDelete: {
                    delete(record)
                    detail = nil
                }
            )
        }
    }

    private var firstName: String {
        NSFullUserName().split(separator: " ").first.map(String.init) ?? "back"
    }

    // MARK: Stats

    private var statsCard: some View {
        HubCard {
            VStack(alignment: .leading, spacing: 16) {
                statLine(value: Self.compact(stats.totalWords), label: "total words")
                statLine(value: stats.averageWPM > 0 ? "\(stats.averageWPM)" : "—", label: "wpm")
                statLine(value: "\(streak)", label: streak == 1 ? "day streak" : "day streak")
                statLine(value: Self.compact(stats.totalDictations), label: "dictations")
            }
            .padding(24)
        }
    }

    private func statLine(value: String, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(value)
                .font(Hub.display(32))
                .foregroundStyle(Hub.ink)
                .monospacedDigit()
            Text(label)
                .font(Hub.text(15))
                .foregroundStyle(Hub.ink)
        }
    }

    static func compact(_ number: Int) -> String {
        switch number {
        case 1_000_000...: return String(format: "%.1fM", Double(number) / 1_000_000)
        case 10_000...: return String(format: "%.1fK", Double(number) / 1_000)
        default: return number.formatted()
        }
    }

    // MARK: Log

    private var timeline: [DictationRecord] {
        records.filter { !$0.displayText.isEmpty && !$0.needsAttention }
    }

    private var attention: [DictationRecord] {
        records.filter(\.needsAttention)
    }

    private var groups: [(day: String, items: [DictationRecord])] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        var result: [(day: String, items: [DictationRecord])] = []
        for record in timeline {
            let day: String
            if calendar.isDateInToday(record.startedAt) {
                day = "Today"
            } else if calendar.isDateInYesterday(record.startedAt) {
                day = "Yesterday"
            } else {
                day = formatter.string(from: record.startedAt)
            }
            if result.last?.day == day {
                result[result.count - 1].items.append(record)
            } else {
                result.append((day, [record]))
            }
        }
        return result
    }

    private var attentionShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HubEyebrow(text: "Needs attention")
            HubCard {
                ForEach(Array(attention.prefix(4).enumerated()), id: \.element.id) { index, record in
                    if index > 0 { HubDivider() }
                    HStack(spacing: 12) {
                        Circle().fill(Hub.warn).frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.attentionTitle).font(Hub.text(14)).foregroundStyle(Hub.ink)
                            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(Hub.text(12)).foregroundStyle(Hub.secondary)
                        }
                        Spacer()
                        if record.canRetry {
                            Button("Retry") { onRetry(record) }
                                .buttonStyle(.plain)
                                .font(Hub.text(13, weight: .semibold))
                                .foregroundStyle(Hub.ink)
                        }
                        HubIconButton(systemImage: "xmark", help: "Discard this recording") { delete(record) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(query.isEmpty ? "Nothing here yet" : "No dictations match “\(query)”")
                .font(Hub.display(22))
                .foregroundStyle(Hub.ink)
            if query.isEmpty {
                Text("Hold fn and start talking. Everything you say shows up here.")
                    .font(Hub.text(14))
                    .foregroundStyle(Hub.secondary)
            }
        }
        .padding(.vertical, 20)
    }

    // MARK: Data

    private func reload() {
        guard let store else { return }
        records = store.records(matching: query.isEmpty ? nil : query, limit: 1_000)
        stats = store.stats()
        streak = Self.streak(days: store.records(limit: 5_000).filter { !$0.displayText.isEmpty }.map(\.startedAt))
    }

    private func delete(_ record: DictationRecord) {
        store?.delete(id: record.id, removeFolder: true)
        reload()
    }

    /// Consecutive days with at least one dictation, counting back from today
    /// (or yesterday, so the streak survives until you dictate today).
    static func streak(days dates: [Date], calendar: Calendar = .current, now: Date = Date()) -> Int {
        let days = Set(dates.map { calendar.startOfDay(for: $0) })
        var cursor = calendar.startOfDay(for: now)
        if !days.contains(cursor) {
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        var count = 0
        while days.contains(cursor) {
            count += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: cursor)!
        }
        return count
    }
}

private struct LogRow: View {
    let record: DictationRecord
    let onOpen: () -> Void
    let onRetry: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false
    @State private var expanded = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            Text(record.startedAt.formatted(date: .omitted, time: .shortened).lowercased())
                .font(Hub.text(13))
                .foregroundStyle(Hub.secondary)
                .frame(width: 70, alignment: .leading)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 6) {
                Text(record.displayText)
                    .font(Hub.text(15))
                    .foregroundStyle(Hub.ink)
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : 6)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let app = record.targetAppName {
                    Text(app)
                        .font(Hub.text(12))
                        .foregroundStyle(Hub.tertiary)
                }
            }
            HStack(spacing: 2) {
                HubIconButton(systemImage: copied ? "checkmark" : "doc.on.doc", help: "Copy") { copy() }
                HubIconButton(systemImage: "ellipsis", help: "Details") { onOpen() }
            }
            .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(hovering ? Hub.hover : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { onOpen() }
        .onTapGesture { expanded.toggle() }
        .contextMenu {
            Button("Copy", action: copy)
            Button("Details…", action: onOpen)
            Button("Retry Transcription", action: onRetry)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(record.displayText, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            copied = false
        }
    }
}

extension DictationRecord {
    var needsAttention: Bool {
        let status = SessionMeta.Status(rawValue: status)
        return displayText.isEmpty || status == .queuedForRetry || status == .failed
    }

    var canRetry: Bool {
        FileManager.default.fileExists(atPath: FileLayout.audioCAF(in: folderURL).path) || rawTranscript != nil
    }

    var attentionTitle: String {
        switch SessionMeta.Status(rawValue: status) {
        case .queuedForRetry: return "Waiting for network"
        case .cancelled:
            return canRetry ? "Cancelled recording — audio kept" : "Cancelled recording — audio deleted by your retention setting"
        case .failed where errorCode == "audio_purged": return "Audio was deleted by your retention setting"
        case .failed where errorCode == "tooNoisy": return "Too noisy — no speech heard"
        case .failed where errorCode == "bad_request": return "Couldn't process this one"
        case .failed where errorCode == "model": return "Model not available to your key — see Settings → Advanced"
        case .failed: return "Transcription failed"
        default: return "Recovered recording"
        }
    }

    var statusDisplayName: String {
        switch SessionMeta.Status(rawValue: status) {
        case .inserted: return "Inserted at the cursor"
        case .copiedToClipboard: return "Copied to the clipboard"
        case .awaitingChip: return "Ready to paste"
        case .recovered: return "Recovered — use Copy to grab the text"
        case .heldSecure: return "Kept — secure field blocked insertion"
        case .queuedForRetry: return "Queued — retries automatically"
        case .cancelled: return "Cancelled"
        case .failed: return "Failed"
        case .silent: return "No speech detected"
        case .recording, .recorded, .transcribing, .none: return status
        }
    }
}

