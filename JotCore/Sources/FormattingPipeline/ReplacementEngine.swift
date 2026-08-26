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

/// Deterministic post-model replacement layer (§3.7): the dictionary's guarantee.
/// The cleanup prompt *suggests* spellings to the model; this layer *enforces* the
/// explicit wrong→right rules afterward. Longest-match-first, word-boundary,
/// case-preserving (ALL-CAPS / Title / lower propagation).
public enum ReplacementEngine {
    public struct Rule: Codable, Equatable, Sendable {
        public var wrong: String
        public var right: String

        public init(wrong: String, right: String) {
            self.wrong = wrong
            self.right = right
        }
    }

    /// A spoken trigger that expands to arbitrary text ("my email address" →
    /// the address itself). Distinct from `Rule`: a spelling rule corrects a word
    /// the model misheard, a snippet substitutes something the user never said in
    /// full. That difference drives two behaviours below — expansions are inserted
    /// VERBATIM (no case propagation; "My number" must not Title-Case a phone
    /// number), and they are never re-scanned.
    public struct Snippet: Codable, Equatable, Sendable {
        public var trigger: String
        public var expansion: String

        public init(trigger: String, expansion: String) {
            self.trigger = trigger
            self.expansion = expansion
        }
    }

    /// Expands snippet triggers in one left-to-right pass over the ORIGINAL text.
    ///
    /// Single-pass is the whole point, not an optimisation. `apply` below rewrites
    /// `result` once per rule, which is harmless for short spelling corrections but
    /// not for snippets: an expansion is arbitrary user text, so a second rule —
    /// or a second snippet — could match INSIDE freshly-inserted content and
    /// corrupt it (expand "my email" to an address, then have a "gmail" rule chew
    /// the domain). Matching against the original and copying the gaps makes that
    /// structurally impossible.
    ///
    /// Longest trigger first so "my work email" beats "my email".
    public static func expand(_ snippets: [Snippet], in text: String) -> String {
        let usable = snippets.filter { !$0.trigger.isEmpty && !$0.expansion.isEmpty }
        guard !usable.isEmpty else { return text }
        // Leftmost-match is NSRegularExpression's; longest-at-a-position is ours,
        // via alternation order (it prefers the earliest listed alternative).
        let ordered = usable.sorted { $0.trigger.count > $1.trigger.count }
        var expansions: [String: String] = [:]
        for snippet in ordered where expansions[snippet.trigger.lowercased()] == nil {
            expansions[snippet.trigger.lowercased()] = snippet.expansion
        }
        let alternation = ordered
            .map { NSRegularExpression.escapedPattern(for: $0.trigger) }
            .joined(separator: "|")
        // Same lookarounds as apply(): \b never matches when a trigger starts or
        // ends in punctuation, and triggers are user-authored phrases.
        let pattern = "(?<![\\w])(?:\(alternation))(?![\\w])"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }

        var out = ""
        var cursor = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            // A match inside a region we already emitted can't happen (matches are
            // non-overlapping and ascending), but the guard keeps the copy honest.
            guard range.lowerBound >= cursor else { continue }
            out += text[cursor..<range.lowerBound]
            let matched = String(text[range]).lowercased()
            out += expansions[matched] ?? String(text[range])
            cursor = range.upperBound
        }
        out += text[cursor...]
        return out
    }

    public static func apply(_ rules: [Rule], to text: String) -> String {
        guard !rules.isEmpty else { return text }
        var result = text
        // Longest wrong-form first so "gemini api" wins over "gemini".
        for rule in rules.sorted(by: { $0.wrong.count > $1.wrong.count }) {
            guard !rule.wrong.isEmpty else { continue }
            // Lookarounds instead of \b: word boundaries silently never match when
            // the wrong form starts/ends with punctuation ("e.g.", "c++") (audit L21).
            let pattern = "(?<![\\w])\(NSRegularExpression.escapedPattern(for: rule.wrong))(?![\\w])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed()
            for match in matches {
                guard let range = Range(match.range, in: result) else { continue }
                let original = String(result[range])
                result.replaceSubrange(range, with: propagateCase(from: original, to: rule.right, wrong: rule.wrong))
            }
        }
        return result
    }

    /// "KUBERNETES"→"GRPC" stays caps; "Kubernetes"→"GRPC"… follows the rule's
    /// canonical casing unless the match was ALL-CAPS or the rule carries
    /// EXPLICIT casing. A rule is explicitly cased when its right side contains
    /// uppercase (gRPC, iPhone) — or when its WRONG side does ("NPM"→"npm" is a
    /// deliberate lowercase rule; ALL-CAPS propagation would silently undo it).
    static func propagateCase(from original: String, to replacement: String, wrong: String = "") -> String {
        let hasExplicitCasing = replacement.dropFirst().contains(where: { $0.isUppercase })
            || replacement.first?.isUppercase == true
            || wrong.contains(where: { $0.isUppercase })
            || (!wrong.isEmpty && wrong.lowercased() == replacement.lowercased())
        if hasExplicitCasing {
            return replacement // dictionary term carries its own casing (gRPC, iPhone)
        }
        if original == original.uppercased(), original.count > 1 {
            return replacement.uppercased()
        }
        if original.first?.isUppercase == true {
            return replacement.prefix(1).uppercased() + replacement.dropFirst()
        }
        return replacement
    }
}
