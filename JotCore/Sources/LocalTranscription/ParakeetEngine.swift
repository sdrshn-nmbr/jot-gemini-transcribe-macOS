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

import FluidAudio
import Foundation

/// Parakeet TDT v2 (English) on the Neural Engine via FluidAudio.
///
/// Loaded once and kept warm: the first load downloads ~600 MB of Core ML
/// weights and compiles them, which is seconds; after that a whole dictation
/// decodes in tens of milliseconds, so there is nothing to gain from streaming.
public actor ParakeetEngine {
    public static let shared = ParakeetEngine()

    private let version: AsrModelVersion = .v2
    private var manager: AsrManager?
    private var loading: Task<AsrManager, Error>?

    public func prepare() async throws -> AsrManager {
        if let manager { return manager }
        if let loading { return try await loading.value }
        let version = version
        let task = Task { () throws -> AsrManager in
            let started = Date()
            let models = try await AsrModels.downloadAndLoad(version: version)
            let asr = AsrManager(config: ASRConfig(
                tdtConfig: TdtConfig(blankId: version.blankId),
                encoderHiddenSize: version.encoderHiddenSize
            ))
            try await asr.loadModels(models)
            Log.transcription.info("parakeet ready in \(Int(Date().timeIntervalSince(started) * 1000))ms")
            return asr
        }
        loading = task
        do {
            let ready = try await task.value
            manager = ready
            loading = nil
            return ready
        } catch {
            loading = nil
            Log.transcription.error("parakeet load FAILED: \(String(describing: error), privacy: .public)")
            throw error
        }
    }

    public func transcribe(audioURL: URL) async throws -> String {
        let asr = try await prepare()
        var samples = try AudioConverter().resampleAudioFile(audioURL)
        // Parakeet refuses clips under its minimum window; a one-word "Continue."
        // is shorter than that. Trailing silence costs nothing and keeps short
        // dictations local.
        let minimum = ASRConstants.minimumRequiredSamples(forSampleRate: 16_000)
        if samples.count < minimum {
            samples += [Float](repeating: 0, count: minimum - samples.count)
        }
        let started = Date()
        var state = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
        let result = try await asr.transcribe(samples, decoderState: &state)
        Log.transcription.info("parakeet \(String(format: "%.1f", Double(samples.count) / 16_000))s audio in \(Int(Date().timeIntervalSince(started) * 1000))ms")
        return result.text
    }
}
