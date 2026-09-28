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

/// Local-first transcription.
///
///   CAF → Parakeet (on device) → style pass → dictionary → inserted text
///
/// A Gemini cleanup call runs only when the speech asks for a rewrite
/// (self-corrections, spoken punctuation, lists). Gemini transcription stays as
/// the fallback when the local model cannot run, and as an explicit choice in
/// Settings.
public struct HybridTranscriptionService: TranscriptionServicing {
    private let engine: ParakeetEngine
    private let gemini: GeminiTranscriptionService
    private let settings: SettingsStore

    public init(
        engine: ParakeetEngine = .shared,
        gemini: GeminiTranscriptionService,
        settings: SettingsStore = SettingsStore()
    ) {
        self.engine = engine
        self.gemini = gemini
        self.settings = settings
    }

    public func transcribe(audioURL: URL, durationSeconds: Double, context: DictationContext) async throws -> TranscriptionResult {
        guard settings.transcriptionEngine == .local else {
            return try await gemini.transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
        }

        let raw: String
        do {
            raw = try await engine.transcribe(audioURL: audioURL)
        } catch {
            Log.transcription.error("local transcription FAILED (\(String(describing: error), privacy: .public)) — falling back to Gemini")
            return try await gemini.transcribe(audioURL: audioURL, durationSeconds: durationSeconds, context: context)
        }
        return try await finish(raw: raw, context: context)
    }

    /// Style, dictionary and — only when the speech asks for it — a model
    /// rewrite of the sentences around a correction. Shared by the file path
    /// and the streaming path.
    public func finish(raw: String, context: DictationContext) async throws -> TranscriptionResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }

        let style = settings.style(for: settings.appGroup(forBundleID: context.targetAppBundleID))
        let local = StyleProfiles.format(trimmed, style: style)

        let groq = GroqClient(apiKey: { KeychainStore.loadGroqKey() })
        guard settings.smartTranscriptionEnabled,
              let window = StyleProfiles.rewriteWindow(trimmed),
              KeychainStore.loadAPIKey() != nil || groq.isConfigured else {
            return TranscriptionResult(
                rawTranscript: trimmed,
                cleanedTranscript: GeminiTranscriptionService.applyDictionary(to: local),
                modelID: "parakeet-v2"
            )
        }

        let config = settings.geminiConfig
        let rewritten = await gemini.cleanupOrFallback(
            raw: window.target, fallback: StyleProfiles.format(window.target, style: style),
            context: context, config: config,
            style: StyleProfiles.promptBlock(for: style), groq: groq
        )
        let joined = [window.prefix, window.suffix].allSatisfy(\.isEmpty)
            ? rewritten
            : [GeminiTranscriptionService.applyDictionary(to: window.prefix), rewritten, GeminiTranscriptionService.applyDictionary(to: window.suffix)]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        let cleaned = [window.prefix, window.suffix].allSatisfy(\.isEmpty) ? joined : StyleProfiles.format(joined, style: style)
        return TranscriptionResult(
            rawTranscript: trimmed,
            cleanedTranscript: cleaned,
            modelID: "parakeet-v2+cleanup"
        )
    }
}
