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

/// Qwen 3.8 27B on Groq, used for the correction rewrite. On real correction
/// snippets it matched Gemini Flash-Lite's accuracy at half the latency
/// (p50 236 ms vs 487 ms), so when a key is present the two race and the
/// first answer that passes the validation gate wins.
public struct GroqClient: Sendable {
    public static let model = "qwen/qwen3.8-27b"
    private let apiKey: @Sendable () -> String?
    private let session: URLSession

    public init(apiKey: @escaping @Sendable () -> String?, session: URLSession = .shared) {
        self.apiKey = apiKey
        self.session = session
    }

    public var isConfigured: Bool { !(apiKey() ?? "").isEmpty }

    public func rewrite(prompt: String, deadline: TimeInterval) async throws -> String {
        guard let key = apiKey(), !key.isEmpty else { throw TranscriptionError.auth }
        var request = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = deadline
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": Self.model,
            "temperature": 0,
            "reasoning_effort": "none",
            "messages": [["role": "user", "content": prompt]],
        ])
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            Log.transcription.error("GroqClient: \(status) — \(String(data: data.prefix(200), encoding: .utf8) ?? "", privacy: .private)")
            throw status == 401 ? TranscriptionError.auth : TranscriptionError.network("groq \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw TranscriptionError.network("groq: unexpected response")
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

