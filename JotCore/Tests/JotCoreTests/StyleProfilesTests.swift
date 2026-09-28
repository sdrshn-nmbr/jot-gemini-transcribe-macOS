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

final class StyleProfilesTests: XCTestCase {
    func testFillerAtSentenceStartIsRemovedAndRecapitalized() {
        XCTAssertEqual(
            StyleProfiles.format("Uh make the phone end look nicer. Um, it's fine.", style: .casual),
            "Make the phone end look nicer. It's fine."
        )
    }

    func testFillerLookalikesInsideWordsSurvive() {
        let text = "The umbrella and the hummus are here."
        XCTAssertEqual(StyleProfiles.format(text, style: .formal), text)
    }

    func testCasualDropsTheFinalPeriodOnlyOnOneSentenceMessages() {
        XCTAssertEqual(StyleProfiles.format("Save me a seat.", style: .casual), "Save me a seat")
        XCTAssertEqual(StyleProfiles.format("Save me a seat. See you soon.", style: .casual), "Save me a seat. See you soon.")
        XCTAssertEqual(StyleProfiles.format("Save me a seat.", style: .formal), "Save me a seat.")
    }

    func testVeryCasualLowercasesButKeepsINamesAndAcronyms() {
        XCTAssertEqual(
            StyleProfiles.format("Sounds good. I'll ship the PR. ClickHouse is up.", style: .veryCasual),
            "sounds good. I'll ship the PR. ClickHouse is up"
        )
    }

    func testRewriteCuesRouteToModel() {
        XCTAssertTrue(StyleProfiles.needsRewrite("let's meet at 2 actually 3"))
        XCTAssertTrue(StyleProfiles.needsRewrite("first item new line second item"))
        XCTAssertFalse(StyleProfiles.needsRewrite("Make sure not to mess up any of the connections."))
    }
}
