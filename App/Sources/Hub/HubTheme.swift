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
import SwiftUI

/// Wispr Flow's hub palette and type, taken from its stylesheet: warm sand
/// neutrals, EB Garamond for headings and numbers, Figtree for everything else.
enum Hub {
    static let chrome = dynamic(light: 0xF5F4F0, dark: 0x1A1A1A)
    static let page = dynamic(light: 0xFCFCFB, dark: 0x141414)
    static let pageEdge = dynamic(light: 0xE9E8E1, dark: 0x2A2A29)
    static let card = dynamic(light: 0xFAF9F7, dark: 0x1F1F1E)
    static let cardEdge = dynamic(light: 0xEEEBE3, dark: 0x30302F)
    static let selected = dynamic(light: 0xEEEBE3, dark: 0x2E2E2C)
    static let hover = dynamic(light: 0xF6F5F1, dark: 0x292928)
    static let ink = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let secondary = dynamic(light: 0x71716E, dark: 0x9D9C98)
    static let tertiary = dynamic(light: 0x9D9C98, dark: 0x71716E)
    static let button = dynamic(light: 0x1A1A1A, dark: 0xE9E8E1)
    static let buttonText = dynamic(light: 0xFCFCFB, dark: 0x141414)
    static let warn = Color(red: 0xEE / 255, green: 0x6A / 255, blue: 0x6A / 255)
    static let star = Color(red: 0xFF / 255, green: 0xA9 / 255, blue: 0x46 / 255)

    static func display(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("EB Garamond", size: size).weight(weight)
    }

    static func text(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom("Figtree", size: size).weight(weight)
    }

    static let eyebrow = Font.custom("Figtree", size: 11).weight(.semibold)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}

/// Page scaffold: serif title, optional trailing controls, scrolling body.
struct HubPage<Trailing: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title)
                            .font(Hub.display(30, weight: .medium))
                            .foregroundStyle(Hub.ink)
                        if let subtitle {
                            Text(subtitle)
                                .font(Hub.text(14))
                                .foregroundStyle(Hub.secondary)
                        }
                    }
                    Spacer()
                    trailing()
                }
                content()
            }
            .padding(.horizontal, 48)
            .padding(.top, 44)
            .padding(.bottom, 40)
            .frame(maxWidth: 1040, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
    }
}

extension HubPage where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, trailing: { EmptyView() }, content: content)
    }
}

/// Rounded sand card with hairline edge; rows inside are separated by dividers.
struct HubCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: 14).fill(Hub.card))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Hub.cardEdge, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

struct HubDivider: View {
    var body: some View {
        Rectangle().fill(Hub.cardEdge).frame(height: 1)
    }
}

struct HubEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(Hub.eyebrow)
            .tracking(1.1)
            .foregroundStyle(Hub.secondary)
    }
}

struct HubPrimaryButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(Hub.text(13, weight: .semibold))
            }
            .foregroundStyle(Hub.buttonText)
            .padding(.horizontal, 14)
            .frame(height: 32)
            .background(Capsule().fill(Hub.button))
        }
        .buttonStyle(.plain)
    }
}

struct HubIconButton: View {
    let systemImage: String
    let help: String
    var tint: Color = Hub.secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Circle().fill(hovering ? Hub.selected : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

struct HubSearchField: View {
    @Binding var text: String
    var prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(Hub.tertiary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(Hub.text(14))
                .foregroundStyle(Hub.ink)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Hub.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
        .background(RoundedRectangle(cornerRadius: 10).fill(Hub.card))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Hub.cardEdge, lineWidth: 1))
    }
}

/// Jot's mark: five bars under the lens envelope the dictation bar uses.
struct JotLogo: View {
    var height: CGFloat = 18
    var body: some View {
        HStack(spacing: height * 0.1) {
            ForEach(Array([0.45, 0.75, 1.0, 0.75, 0.45].enumerated()), id: \.offset) { _, scale in
                RoundedRectangle(cornerRadius: height * 0.06)
                    .fill(Hub.ink)
                    .frame(width: height * 0.12, height: height * scale)
            }
        }
        .frame(height: height)
    }
}

