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

/// Wispr Flow's bar, measured from its stylesheet: a 30pt black capsule with a
/// 1pt #30302f edge. 73pt wide while holding, 102.5pt hands-free, 98pt while
/// processing; a 40×8 translucent sliver at rest that opens to 50×30 on hover.
enum Flow {
    static let ink = Color.black
    static let edge = Color(red: 0x30 / 255, green: 0x30 / 255, blue: 0x2f / 255)
    static let edgeHover = Color(red: 0x5b / 255, green: 0x5b / 255, blue: 0x59 / 255)
    static let text = Color(red: 0xb3 / 255, green: 0xb2 / 255, blue: 0xad / 255)
    static let hint = Color(red: 0xfc / 255, green: 0xfc / 255, blue: 0xfb / 255).opacity(0.4)
    static let button = Color(red: 0x5b / 255, green: 0x5b / 255, blue: 0x59 / 255)
    static let buttonText = Color(red: 0xfc / 255, green: 0xfc / 255, blue: 0xfb / 255)
    static let destructive = Color(red: 0xee / 255, green: 0x6a / 255, blue: 0x6a / 255)
    static let height: CGFloat = 30
    static let morph = Animation.timingCurve(0.05, 0.6, 0.4, 0.95, duration: 0.18)
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}

struct PillView: View {
    @ObservedObject var model: PillModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .animation(reduceMotion ? .linear(duration: 0.12) : Flow.spring, value: model.state)
            .accessibilityElement(children: hasInteractiveControls ? .contain : .ignore)
            .accessibilityLabel(accessibilityDescription)
    }

    private var hasInteractiveControls: Bool {
        switch model.state {
        case .idleDot, .listening(locked: true), .transcript: return true
        default: return false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .hidden:
            EmptyView()

        case .idleDot, .success:
            RestingBar()

        case .listening(let locked):
            if model.partial.isEmpty {
                bar(width: locked ? 102.5 : 73) {
                    HStack(spacing: 10) {
                        WaveformView(level: model.level, processing: false)
                        if locked { stopButton }
                    }
                }
            } else {
                bar(width: 420) {
                    HStack(spacing: 10) {
                        WaveformView(level: model.level, processing: false)
                        partialText
                        if locked { stopButton }
                    }
                }
            }

        case .processing:
            if model.partial.isEmpty {
                bar(width: 98) {
                    WaveformView(level: 0, processing: true)
                }
            } else {
                bar(width: 420) {
                    HStack(spacing: 10) {
                        WaveformView(level: 0, processing: true)
                        if model.correction.isEmpty {
                            partialText
                        } else {
                            CorrectionView(segments: model.correction)
                                .id(model.corrected)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
            }

        case .notice(let message):
            bar(width: nil) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Flow.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
            }

        case .error(let message):
            bar(width: nil, edge: Flow.destructive, edgeWidth: 1.5) {
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Flow.text)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
            }
            .modifier(ShakeEffect(shakes: reduceMotion ? 0 : 3))

        case .transcript(let text):
            TranscriptCard(text: text, timeout: PillModel.transcriptTimeout)
        }
    }

    private var partialText: some View {
        Text(model.partial)
            .font(.system(size: 12))
            .foregroundStyle(Flow.text)
            .lineLimit(1)
            .truncationMode(.head)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .animation(nil, value: model.partial)
            .accessibilityHidden(true)
            .geminiSweep(trigger: model.corrected)
    }

    private func bar<Content: View>(
        width: CGFloat?,
        edge: Color = Flow.edge,
        edgeWidth: CGFloat = 1,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .padding(.horizontal, 12)
            .frame(width: width, height: Flow.height)
            .frame(maxWidth: width == nil ? 560 : nil)
            .background(Capsule().fill(Flow.ink))
            .overlay(Capsule().strokeBorder(edge, lineWidth: edgeWidth))
            .clipShape(Capsule())
            .transition(.scale(scale: 0.7, anchor: .bottom).combined(with: .opacity))
    }

    private var stopButton: some View {
        Button {
            NotificationCenter.default.post(name: .pillStopTapped, object: nil)
        } label: {
            ZStack {
                Circle().fill(Color(white: 0.16))
                RoundedRectangle(cornerRadius: 2)
                    .fill(Flow.destructive)
                    .frame(width: 7.5, height: 7.5)
            }
            .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop dictation and insert text")
    }

    private var accessibilityDescription: String {
        switch model.state {
        case .hidden, .idleDot: return "Jot — ready"
        case .listening(true): return "Listening — hands-free locked"
        case .listening(false): return "Listening"
        case .processing: return "Processing"
        case .success(let words): return "Inserted\(words.map { " \($0) words" } ?? "")"
        case .notice(let message): return message
        case .error(let message): return "Error — \(message)"
        case .transcript(let text): return "No text field — \(text)"
        }
    }
}

// MARK: - Resting bar

/// 40×8 translucent sliver; on hover it opens into the 50×30 black bar with
/// dim bars. Click starts hands-free.
private struct RestingBar: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NotificationCenter.default.post(name: .pillDotTapped, object: nil)
        } label: {
            ZStack {
                if hovering {
                    WaveformView(level: 0, processing: true)
                        .transition(.opacity)
                }
            }
            .frame(width: hovering ? 50 : 40, height: hovering ? Flow.height : 8)
            .background(
                RoundedRectangle(cornerRadius: hovering ? Flow.height / 2 : 6)
                    .fill(hovering ? Flow.ink : Color.black.opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: hovering ? Flow.height / 2 : 6)
                    .strokeBorder(hovering ? Flow.edgeHover : Color.white.opacity(0.5), lineWidth: 1)
            )
            .contentShape(Rectangle().inset(by: -12))
            .animation(Flow.morph, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Start hands-free dictation")
        .accessibilityLabel("Start hands-free dictation")
    }
}

// MARK: - No text field card

/// Shown when the transcript had nowhere to go: the words, a Copy button, and
/// a close button whose ring counts down to dismissal. Hover pauses the clock.
private struct TranscriptCard: View {
    let text: String
    let timeout: TimeInterval

    @State private var copied = false
    @State private var remaining: Double = 1
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                HStack(spacing: 6) {
                    JotMark()
                    Text("Select a textbox first, then dictate")
                        .font(.system(size: 12))
                        .foregroundStyle(Flow.hint)
                }
                Spacer(minLength: 8)
                closeButton
                    .padding(.top, -2)
            }
            .padding(.bottom, 12)

            ScrollView {
                Text(text)
                    .font(.system(size: 15))
                    .lineSpacing(3)
                    .foregroundStyle(Flow.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 180)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(action: copy) {
                    Text(copied ? "Copied!" : "Copy")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Flow.buttonText)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Flow.button))
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 12)
        }
        .padding(16)
        .frame(width: 384)
        .background(RoundedRectangle(cornerRadius: 16).fill(Flow.ink))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Flow.edge, lineWidth: 1))
        .onHover { hovering = $0 }
        .transition(.scale(scale: 0.9, anchor: .bottom).combined(with: .opacity))
        .task(id: text) { await countDown() }
    }

    private var closeButton: some View {
        Button(action: dismiss) {
            ZStack {
                Circle().strokeBorder(Color.white.opacity(0.12), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: remaining)
                    .stroke(Color.white.opacity(0.7), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(0.75)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Flow.buttonText)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss")
    }

    private func countDown() async {
        let step = 0.05
        var left = timeout
        while left > 0 {
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            if Task.isCancelled { return }
            if !hovering { left -= step }
            remaining = max(0, left / timeout)
        }
        dismiss()
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            dismiss()
        }
    }

    private func dismiss() {
        NotificationCenter.default.post(name: .pillTranscriptDismissed, object: nil)
    }
}

/// Jot's mark at 16pt: five bars under the same lens envelope as the waveform.
private struct JotMark: View {
    var body: some View {
        HStack(spacing: 1.5) {
            ForEach([6.0, 10, 14, 10, 6], id: \.self) { height in
                RoundedRectangle(cornerRadius: 0.75)
                    .fill(Flow.buttonText)
                    .frame(width: 1.5, height: height)
            }
        }
        .frame(width: 16, height: 16)
    }
}

// MARK: - Effects

private struct ShakeEffect: ViewModifier {
    var shakes: Int
    @State private var animating = false

    func body(content: Content) -> some View {
        content
            .modifier(ShakeGeometry(travel: 4, shakes: CGFloat(shakes), progress: animating ? 1 : 0))
            .onAppear {
                withAnimation(.timingCurve(0.36, 0.07, 0.19, 0.97, duration: 0.25)) {
                    animating = true
                }
            }
    }
}

private struct ShakeGeometry: GeometryEffect {
    var travel: CGFloat
    var shakes: CGFloat
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(progress * .pi * shakes * 2), y: 0
        ))
    }
}

extension Notification.Name {
    static let pillStopTapped = Notification.Name("com.ammaar.jot.pill.stop")
    static let pillDotTapped = Notification.Name("com.ammaar.jot.pill.dot")
    static let pillTranscriptDismissed = Notification.Name("com.ammaar.jot.pill.transcript-dismissed")
}

