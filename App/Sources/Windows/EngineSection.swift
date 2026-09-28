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

import JotCore
import SwiftUI

/// Where the words come from. Shown at the top of Settings → Dictation.
struct EngineSection: View {
    private let settings = SettingsStore()
    @State private var engine = SettingsStore().transcriptionEngine

    var body: some View {
        Section {
            Picker("Transcription", selection: $engine) {
                Text("On this Mac (Parakeet)").tag(TranscriptionEngine.local)
                Text("Gemini").tag(TranscriptionEngine.gemini)
            }
            .onChange(of: engine) { _, value in
                settings.setTranscriptionEngine(value)
                if value == .local {
                    Task.detached(priority: .utility) { _ = try? await ParakeetEngine.shared.prepare() }
                }
            }
        } footer: {
            Text(engine == .local
                 ? "Words are recognized on this Mac in well under a second, and audio never leaves it. Gemini is used only when you correct yourself or dictate punctuation or lists, and only the text is sent."
                 : "Audio is uploaded to Gemini for every dictation.")
        }
    }
}

