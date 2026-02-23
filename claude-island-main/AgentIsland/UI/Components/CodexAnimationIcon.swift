//
//  CodexAnimationIcon.swift
//  AgentIsland
//
//  Static Codex icon.
//

import SwiftUI

struct CodexAnimationIcon: View {
    let size: CGFloat
    var isAnimating: Bool = true
    var fallbackColor: Color = Color(red: 0.24, green: 0.52, blue: 0.96)

    private let spinDuration: TimeInterval = 0.65
    private let pauseDuration: TimeInterval = 0.6

    var body: some View {
        Group {
            if isAnimating {
                TimelineView(.animation) { timeline in
                    icon
                        .rotationEffect(.degrees(rotation(at: timeline.date)))
                }
            } else {
                icon
            }
        }
        .frame(width: size, height: size)
        .clipped()
    }

    private var icon: some View {
        Image("OpenAIIcon")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .foregroundColor(fallbackColor)
    }

    private func rotation(at date: Date) -> Double {
        let cycleDuration = spinDuration + pauseDuration
        let timeInCycle = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration)
        if timeInCycle <= spinDuration {
            return (timeInCycle / spinDuration) * 360.0
        }
        return 360.0
    }
}
