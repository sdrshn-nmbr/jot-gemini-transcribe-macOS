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

@testable import JotCore
import XCTest

final class ScratchpadMergeTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    private func note(_ id: UUID, _ text: String, at seconds: Double) -> ScratchNote {
        var note = ScratchNote(id: id, text: "", now: t0)
        note.record(.typed, text: text, rtf: nil, now: t0.addingTimeInterval(seconds))
        return note
    }

    func testEditsOnTwoMacsKeepTheNewerVersionOfEachNote() {
        let a = UUID(), b = UUID()
        let local = ScratchpadStore.Contents(notes: [note(a, "a newer here", at: 20), note(b, "b older here", at: 5)])
        let remote = ScratchpadStore.Contents(notes: [note(a, "a older there", at: 10), note(b, "b newer there", at: 30)])
        let merged = ScratchpadStore.merge(local, remote)
        XCTAssertEqual(Set(merged.notes.map(\.text)), ["a newer here", "b newer there"])
    }

    func testDeleteBeatsAnOlderEditButNotANewerOne() {
        let gone = UUID(), revived = UUID()
        let local = ScratchpadStore.Contents(notes: [note(gone, "stale", at: 5), note(revived, "edited after delete", at: 50)])
        let remote = ScratchpadStore.Contents(deleted: [gone: t0.addingTimeInterval(10), revived: t0.addingTimeInterval(40)])
        let merged = ScratchpadStore.merge(local, remote)
        XCTAssertEqual(merged.notes.map(\.text), ["edited after delete"])
        XCTAssertNotNil(merged.deleted[gone])
    }

    func testMergeIsIdempotent() {
        let local = ScratchpadStore.Contents(notes: [note(UUID(), "one", at: 1)])
        let remote = ScratchpadStore.Contents(notes: [note(UUID(), "two", at: 2)])
        let once = ScratchpadStore.merge(local, remote)
        XCTAssertEqual(ScratchpadStore.merge(once, once), once)
        XCTAssertEqual(ScratchpadStore.merge(once, remote), once)
    }
}
