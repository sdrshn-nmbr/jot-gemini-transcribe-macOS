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

    func testSpokenCorrectionsAndFormattingNeedTheModel() {
        let corrections = [
            "Let's meet at 2, actually 3.",
            "Let's schedule the meeting for 1pm. Actually make that 2pm.",
            "Book a table for four people. Sorry, I mean five people.",
            "Push the branch to main. Wait no, push it to dev.",
            "The deploy is at 3. Scratch that, it's at 4.",
            "One bedroom is fine. Actually, change one bedroom to studio.",
            "Send it Monday, or rather Tuesday.",
            "I said Vercel but I meant Netlify.",
            "What time is the standup tomorrow question mark",
            "Milk new line eggs new line bread",
            "Number one milk. Number two eggs.",
        ]
        for text in corrections {
            XCTAssertTrue(StyleProfiles.needsRewrite(text), text)
        }
    }

    /// Taken from real dictations that went to the model for nothing.
    func testOrdinarySpeechStaysLocal() {
        let ordinary = [
            "Who has actually mastered using Jev for long horizon tasks?",
            "Determine if it's actually usable for the same use cases.",
            "Be proactive rather than just reactive or interactive.",
            "Local record of recent activity is actually just going to be in the web app.",
            "I mean, of course, if you go to schools like MIT it's different.",
            "They're both focusing on enterprise agents rather than consumer.",
            "The trial period ends on Friday.",
            "Our number one priority is latency.",
            "Sorry for the late reply.",
        ]
        for text in ordinary {
            XCTAssertFalse(StyleProfiles.needsRewrite(text), text)
        }
    }

    func testOnlyTheSentencesAroundACorrectionAreRewritten() {
        let text = "We shipped the parser. Tests are green. The demo is at 3. Scratch that, it's at 4. See you there."
        let window = StyleProfiles.rewriteWindow(text)
        XCTAssertEqual(window?.prefix, "We shipped the parser. Tests are green. ")
        XCTAssertEqual(window?.target, "The demo is at 3. Scratch that, it's at 4. ")
        XCTAssertEqual(window?.suffix, "See you there.")
    }

    func testShortTextIsRewrittenWhole() {
        let text = "Meet at 1pm. Actually make that 2pm."
        XCTAssertEqual(StyleProfiles.rewriteWindow(text)?.target, text)
        XCTAssertEqual(StyleProfiles.rewriteWindow(text)?.prefix, "")
    }
}
