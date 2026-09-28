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

    /// Phrases that mean the words as spoken are not the words wanted. Each is
    /// narrowed to the way people correct themselves: "actually" only where it
    /// opens a clause or precedes a number, never "is actually usable"; "or
    /// rather", never "rather than". On 68 real dictations the broad words sent
    /// 12 to the model and only 3 were corrections.
    private static let rewriteCues: [NSRegularExpression] = [
        #"(?:^|[.,;:!?]\s*)actually\b"#,
        #"\bactually,?\s+(?:no\b|make (?:that|it)\b|change\b|\d)"#,
        #"\bscratch that\b"#,
        #"\b(?:no|wait),?\s+(?:no|wait)\b"#,
        #"\bI meant\b"#,
        #"\b(?:sorry|no),?\s+I mean\b"#,
        #"\bor rather\b"#,
        #"(?:^|[.,;]\s*)correction\b"#,
        #"\bnew ?(?:line|paragraph)\b"#,
        #"\b(?:question mark|exclamation (?:point|mark)|full stop|semicolon|bullet point)\b"#,
        #"\b(?:open|close) (?:paren|parenthesis|quote|bracket)\b"#,
        #"\bcomma\b"#,
        #"(?<!\b(?:a|the|this|that|time|grace|trial|waiting|billing|same|short|long|any|each|free)\s)\bperiod\b"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// A spoken list needs at least two numbered items; "number one priority"
    /// alone is ordinary speech.
    private static let listItem = try! NSRegularExpression(
        pattern: #"\bnumber (?:one|two|three|four|five|[1-5])\b"#, options: [.caseInsensitive]
    )

    private static let fillers = try! NSRegularExpression(
        pattern: #"(?<![\w'])(?:u+m+|u+h+|e+r+m+|h+m+|mhm)(?![\w'])[,.]?\s*"#,
        options: [.caseInsensitive]
    )

    public static func needsRewrite(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        if rewriteCues.contains(where: { $0.firstMatch(in: text, range: range) != nil }) { return true }
        return listItem.numberOfMatches(in: text, range: range) >= 2
    }

    /// The part of a dictation the model should rewrite, with the untouched
    /// sentences either side. A correction reaches back one sentence at most,
    /// so a two-minute dictation with one "scratch that" sends two sentences to
    /// the model instead of all of them — the rewrite time stops growing with
    /// the length of what you said.
    public struct RewriteWindow: Equatable {
        public let prefix: String
        public let target: String
        public let suffix: String
    }

    public static func rewriteWindow(_ text: String) -> RewriteWindow? {
        let sentences = splitSentences(text)
        let flagged = sentences.indices.filter { needsRewrite(sentences[$0]) }
        let lists = sentences.indices.filter { index in
            listItem.firstMatch(in: sentences[index], range: NSRange(sentences[index].startIndex..., in: sentences[index])) != nil
        }
        let hits = flagged + (lists.count >= 2 ? lists : [])
        guard let first = hits.min(), let last = hits.max() else {
            return needsRewrite(text) ? RewriteWindow(prefix: "", target: text, suffix: "") : nil
        }
        let start = max(0, first - 1)
        let end = min(sentences.count - 1, lists.count >= 2 && last == lists.max() ? last + 1 : last)
        if end - start + 1 >= sentences.count - 1 {
            return RewriteWindow(prefix: "", target: text, suffix: "")
        }
        return RewriteWindow(
            prefix: sentences[..<start].joined(),
            target: sentences[start...end].joined(),
            suffix: sentences[(end + 1)...].joined()
        )
    }

    /// Sentences with their trailing punctuation and spaces kept, so joining
    /// them gives back the original text exactly.
    static func splitSentences(_ text: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+|$)\s*"#)
        let matches = pattern.matches(in: text, range: NSRange(text.startIndex..., in: text))
        let pieces = matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } }
        return pieces.joined() == text ? pieces : [text]
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
