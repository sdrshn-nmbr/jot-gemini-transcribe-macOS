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

/// While the scratchpad has the keyboard, dictation goes straight into it;
/// everything else goes through the normal insertion ladder.
@MainActor
struct AppInserter: TextInserting {
    let base = InsertionCoordinator()

    @MainActor func insert(_ text: String, context: DictationContext) async -> InsertionOutcome {
        if ScratchpadModel.shared.insertDictation(text) {
            return .inserted
        }
        return await base.insert(text, context: context)
    }
}
