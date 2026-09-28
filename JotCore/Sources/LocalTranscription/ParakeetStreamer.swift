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

/// Transcribes long dictations while you are still talking.
///
/// Audio arrives through the live seam as 16 kHz mono Int16. Once 30 seconds
/// have piled up past the last cut, the quietest moment in the next few
/// seconds becomes a cut point and everything before it is transcribed in the
/// background. At key-up only the stretch since the last cut is left, so a
/// five-minute dictation finishes as fast as a twenty-second one. Short
/// dictations never cut and are transcribed in one pass, exactly like the file.
///
/// Anything unexpected returns nil from `finish`, and the coordinator
/// transcribes the recording on disk instead.
public final class ParakeetStreamer: LiveTranscribing, @unchecked Sendable {
    static let rate = 16_000
    static let chunkSeconds = 30
    static let searchSeconds = 4

    private let engine: ParakeetEngine
    private let finalize: @Sendable (String) async throws -> TranscriptionResult
    private let lock = NSLock()
    private var samples: [Float] = []
    private var committed = 0
    private var texts: [String] = []
    private var job: Task<Void, Never>?
    private var failed = false
    private var aborted = false

    public init(engine: ParakeetEngine = .shared, finalize: @escaping @Sendable (String) async throws -> TranscriptionResult) {
        self.engine = engine
        self.finalize = finalize
        samples.reserveCapacity(Self.rate * 60)
    }

    public var partials: AsyncStream<String> { AsyncStream { $0.finish() } }

    public func begin() async throws {}

    public nonisolated func enqueue(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !aborted else { return }
        pcm.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Int16.self) {
                samples.append(Float(value) / 32_768)
            }
        }
        startChunkIfDue()
    }

    /// Must be called with the lock held.
    private func startChunkIfDue() {
        let due = committed + (Self.chunkSeconds + Self.searchSeconds) * Self.rate
        guard job == nil, !failed, samples.count >= due else { return }
        let cut = Self.quietestCut(in: samples, from: committed + Self.chunkSeconds * Self.rate, to: due)
        let slice = Array(samples[committed..<cut])
        committed = cut
        job = Task { [weak self] in
            guard let self else { return }
            let text = try? await self.engine.transcribe(samples: slice)
            self.lock.lock()
            if let text { self.texts.append(text) } else { self.failed = true }
            self.job = nil
            self.startChunkIfDue()
            self.lock.unlock()
        }
    }

    /// The start of the quietest 200 ms window, scanned in 50 ms steps.
    static func quietestCut(in samples: [Float], from start: Int, to end: Int) -> Int {
        let window = rate / 5
        let step = rate / 20
        var best = end
        var bestEnergy = Float.greatestFiniteMagnitude
        var index = start
        while index + window <= end {
            var energy: Float = 0
            for sample in samples[index..<(index + window)] { energy += sample * sample }
            if energy < bestEnergy {
                bestEnergy = energy
                best = index + window / 2
            }
            index += step
        }
        return best
    }

    /// Waits for background chunks. Exposed so a benchmark can model the time
    /// that passes while you speak.
    public func settle() async {
        while let running = currentJob() { await running.value }
    }

    private func currentJob() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        return job
    }

    public func finish(deadline: TimeInterval, framesWritten: Int64) async -> TranscriptionResult? {
        await settle()
        lock.lock()
        let tail = Array(samples[committed...])
        let total = samples.count
        let done = texts
        let broken = failed
        lock.unlock()
        guard !broken, total == Int(framesWritten) else {
            Log.transcription.info("local stream incomplete (\(total) of \(framesWritten) samples) — transcribing the file")
            return nil
        }
        let last = tail.isEmpty ? "" : ((try? await engine.transcribe(samples: tail)) ?? "\u{0}")
        guard last != "\u{0}" else { return nil }
        let raw = (done + [last])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !raw.isEmpty else { return nil }
        if !done.isEmpty {
            Log.transcription.info("local stream: \(done.count) chunk(s) done while speaking, \(String(format: "%.1f", Double(tail.count) / Double(Self.rate)))s left at key-up")
        }
        return try? await finalize(raw)
    }

    public func abort() async {
        lock.lock()
        aborted = true
        let running = job
        lock.unlock()
        running?.cancel()
    }
}

