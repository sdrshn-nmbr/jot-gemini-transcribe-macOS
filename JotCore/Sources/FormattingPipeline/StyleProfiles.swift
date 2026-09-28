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

/// The local formatting path. Parakeet already writes punctuated, capitalised
/// sentences, so most dictations need only filler removal and a style pass —
/// microseconds instead of a model round trip. The model is reserved for speech
/// that asks for a rewrite: self-corrections and spoken formatting.
public enum StyleProfiles {
    public static let builtInGroups: [String: AppGroup] = [
        "com.tinyspeck.slackmacgap": .work,
        "com.microsoft.teams2": .work,
        "com.linear": .work,
        "com.hnc.Discord": .work,
        "com.apple.mail": .email,
        "com.google.Gmail": .email,
        "com.microsoft.Outlook": .email,
        "com.superhuman.electron": .email,
        "com.readdle.smartemail-Mac": .email,
        "com.apple.MobileSMS": .personal,
        "net.whatsapp.WhatsApp": .personal,
        "ru.keepcoder.Telegram": .personal,
        "com.facebook.archon": .personal,
    ]

    /// Phrases that mean the words as spoken are not the words wanted.
    private static let rewriteCues = try! NSRegularExpression(
        pattern: #"\b(actually|scratch that|i mean|no wait|wait no|sorry|rather|correction|new line|newline|new paragraph|period|full stop|comma|question mark|exclamation (?:point|mark)|colon|semicolon|open (?:paren|quote)|close (?:paren|quote)|bullet|number (?:one|two|three|1|2|3)|first(?:ly)?,? second(?:ly)?)\b"#,
        options: [.caseInsensitive]
    )

    private static let fillers = try! NSRegularExpression(
        pattern: #"(?<![\w'])(?:u+m+|u+h+|e+r+m+|h+m+|mhm)(?![\w'])[,.]?\s*"#,
        options: [.caseInsensitive]
    )

    public static func needsRewrite(_ text: String) -> Bool {
        rewriteCues.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func format(_ text: String, style: WritingStyle) -> String {
        let stripped = fillers.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
        )
        var result = recapitalizeSentenceStarts(stripped.trimmingCharacters(in: .whitespacesAndNewlines))
        switch style {
        case .formal:
            break
        case .casual:
            if isSingleSentence(result), result.hasSuffix("."), !result.hasSuffix("..") { result.removeLast() }
        case .veryCasual:
            result = lowercaseSentenceStarts(result)
            if result.hasSuffix("."), !result.hasSuffix("..") { result.removeLast() }
        }
        return result
    }

    /// Filler removal can leave "uh make it" as "make it" at a sentence start.
    private static func isSingleSentence(_ text: String) -> Bool {
        text.dropLast().allSatisfy { !".!?".contains($0) }
    }

    private static func recapitalizeSentenceStarts(_ text: String) -> String {
        mapSentenceStarts(text) { $0.uppercased() }
    }

    /// Lowercases the first letter of each sentence unless the word is "I" or
    /// looks like a name or acronym (a second capital inside the word).
    private static func lowercaseSentenceStarts(_ text: String) -> String {
        mapSentenceStarts(text) { $0.lowercased() }
    }

    private static func mapSentenceStarts(_ text: String, _ transform: (String) -> String) -> String {
        var output = ""
        var atStart = true
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if atStart, character.isLetter {
                let wordEnd = text[index...].firstIndex(where: { !$0.isLetter && $0 != "'" }) ?? text.endIndex
                let word = String(text[index..<wordEnd])
                let keep = word == "I" || word.hasPrefix("I'") || word.dropFirst().contains(where: \.isUppercase)
                output += keep ? word : transform(String(word.prefix(1))) + word.dropFirst()
                index = wordEnd
                atStart = false
                continue
            }
            output.append(character)
            if ".!?".contains(character) {
                atStart = true
            } else if !character.isWhitespace && character != "\"" && character != "(" {
                atStart = false
            }
            index = text.index(after: index)
        }
        return output
    }

    /// The style line appended to the cleanup prompt when the model does run.
    public static func promptBlock(for style: WritingStyle) -> String {
        switch style {
        case .formal:
            return "Style: formal. Full capitalization and punctuation."
        case .casual:
            return "Style: casual. Normal capitalization, light punctuation. Keep the speaker's slang and contractions exactly."
        case .veryCasual:
            return "Style: very casual. Lowercase sentence starts (keep names, acronyms and \"I\" capitalized), minimal punctuation, no trailing period. Keep slang and contractions exactly."
        }
    }
}
