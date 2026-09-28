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
import AVFoundation
import SwiftUI
import JotCore

// MARK: - Detail sheet

struct RecordDetailSheet: View {
    let record: DictationRecord
    let onRetry: () -> Void
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showRaw = false
    @State private var player: AVAudioPlayer?
    private var grad: CGFloat { scheme == .dark ? 25 : 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: JotUI.Spacing.m) {
            HStack {
                // Native smart transcription formats as it transcribes, so on the
                // default path there is no separate raw text to compare against —
                // the two tabs would be byte-identical. A segmented control whose
                // halves match reads as broken, so it only appears when a second
                // model actually rewrote something.
                if hasDistinctRaw {
                    Picker("", selection: $showRaw) {
                        Text("Cleaned").tag(false)
                        Text("Raw").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 170)
                }
                Spacer()
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(shownText, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }

            ScrollView {
                Text(shownText)
                    .font(JotUI.TypeScale.bodyLarge(grad: grad))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 260)

            HStack(spacing: JotUI.Spacing.s) {
                audioButton
                Button("Retry Transcription") { onRetry() }
                Spacer()
                Button(role: .destructive) { onDelete() } label: {
                    Image(systemName: "trash")
                }
                .help("Delete this dictation")
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: JotUI.Spacing.l, verticalSpacing: 4) {
                if let app = record.targetAppName {
                    GridRow {
                        metaLabel("Dictated into"); metaValue(app)
                    }
                }
                if let duration = record.durationSeconds {
                    GridRow {
                        metaLabel("Duration"); metaValue(String(format: "%.1fs", duration))
                    }
                }
                if let pipeline = record.pipelineSeconds {
                    GridRow {
                        metaLabel("Pipeline"); metaValue(String(format: "%.2fs", pipeline))
                    }
                }
                GridRow {
                    metaLabel("Status"); metaValue(record.statusDisplayName)
                }
                if let message = record.errorMessage, !message.isEmpty {
                    GridRow {
                        metaLabel("Details"); metaValue(String(message.prefix(160)))
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(JotUI.Spacing.l)
        .frame(width: 520)
        .onDisappear { player?.stop() }
    }

    private var hasDistinctRaw: Bool {
        guard let raw = record.rawTranscript, let clean = record.cleanedTranscript else { return false }
        return raw != clean
    }

    private var shownText: String {
        (showRaw && hasDistinctRaw) ? (record.rawTranscript ?? "—")
                : (record.cleanedTranscript ?? record.rawTranscript ?? "—")
    }

    @ViewBuilder
    private var audioButton: some View {
        let cafURL = FileLayout.audioCAF(in: record.folderURL)
        if FileManager.default.fileExists(atPath: cafURL.path) {
            Button {
                if player?.isPlaying == true {
                    player?.stop()
                    player = nil
                } else {
                    player = try? AVAudioPlayer(contentsOf: cafURL)
                    player?.play()
                }
            } label: {
                Label(player?.isPlaying == true ? "Stop" : "Play Audio",
                      systemImage: player?.isPlaying == true ? "stop.fill" : "play.fill")
            }
        } else {
            Text("Audio removed by retention policy")
                .font(JotUI.TypeScale.labelSmall(grad: grad))
                .foregroundStyle(.secondary)
        }
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text).font(JotUI.TypeScale.labelSmall(grad: grad)).foregroundStyle(.secondary)
    }

    private func metaValue(_ text: String) -> some View {
        Text(text).font(JotUI.TypeScale.labelSmall(grad: grad))
    }
}
