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

import SwiftUI

/// Ten 2pt bars under a lens-shaped envelope: each bar's reach falls off as
/// 1 − d²/48 from the centre, and a 1s swell (1 → 1.2 → 1.5 → 1.1 → 1.3 → 1)
/// travels outward from the middle at 0.1s per bar.
struct WaveformView: View {
    var level: Float
    var processing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let count = 10
    private static let barWidth: CGFloat = 2
    private static let gap: CGFloat = 2
    private static let height: CGFloat = 18
    private static let swell: [(t: Double, v: Double)] = [(0, 1), (0.2, 1.2), (0.4, 1.5), (0.8, 1.1), (0.9, 1.3), (1, 1)]

    private final class Smoother {
        var value: CGFloat = 0
        func step(toward target: CGFloat) -> CGFloat {
            value += (target - value) * (target > value ? 0.45 : 0.12)
            return value
        }
    }

    @State private var smoother = Smoother()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            Canvas { context, size in
                draw(&context, size: size, time: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
        .frame(width: CGFloat(Self.count) * Self.barWidth + CGFloat(Self.count - 1) * Self.gap, height: Self.height)
    }

    private func draw(_ context: inout GraphicsContext, size: CGSize, time: Double) {
        let loudness = smoother.step(toward: processing ? 0.12 : CGFloat(min(max(level, 0), 1)))
        let centre = Double(Self.count - 1) / 2
        let colour: Color = processing ? .white.opacity(0.4) : .white
        for index in 0..<Self.count {
            let distance = abs(centre - Double(index))
            let bulge = max(0, 1 - distance * distance / 48)
            let lag = Double(index < Self.count / 2 ? index : index - Self.count) * 0.1
            let swell = reduceMotion ? 1 : Self.swellValue(at: time - lag)
            let reach = (2 + loudness * 12) * CGFloat(bulge * swell)
            let barHeight = min(max(reach, Self.barWidth), size.height)
            let rect = CGRect(
                x: CGFloat(index) * (Self.barWidth + Self.gap),
                y: (size.height - barHeight) / 2,
                width: Self.barWidth,
                height: barHeight
            )
            context.fill(Path(roundedRect: rect, cornerRadius: 0.5), with: .color(colour))
        }
    }

    private static func swellValue(at time: Double) -> Double {
        let phase = time - floor(time)
        for (a, b) in zip(swell, swell.dropFirst()) where phase <= b.t {
            let progress = (phase - a.t) / (b.t - a.t)
            let eased = progress * progress * (3 - 2 * progress)
            return a.v + (b.v - a.v) * eased
        }
        return 1
    }
}

