import SwiftUI

/// A subtle three-dot typing indicator that pulses in sequence.
/// Use as a lightweight alternative to `ProgressView` when waiting for
/// streamed text or tool results.
struct AgentTypingIndicator: View {
    var dotSize: CGFloat = 6
    var color: Color = .secondary
    var spacing: CGFloat = 4

    @State private var phase: Int = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(0..<3) { index in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
                    .opacity(phase == index ? 1.0 : 0.3)
                    .scaleEffect(phase == index ? 1.15 : 0.85)
                    .animation(.easeInOut(duration: 0.4), value: phase)
            }
        }
        .onAppear { startAnimating() }
        .onDisappear { animationTask?.cancel(); animationTask = nil }
        .accessibilityLabel(Text("Agent is typing"))
    }

    private func startAnimating() {
        // Cancelled on disappear — the fire-and-forget version leaked one
        // perpetual MainActor task per bubble instance.
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { break }
                phase = (phase + 1) % 3
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        AgentTypingIndicator()
        AgentTypingIndicator(dotSize: 8, color: .accentColor, spacing: 6)
    }
    .padding()
}
