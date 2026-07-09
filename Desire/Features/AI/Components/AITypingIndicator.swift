import SwiftUI

/// A subtle three-dot typing indicator that pulses in sequence.
/// Use as a lightweight alternative to `ProgressView` when waiting for
/// streamed text or tool results.
struct AITypingIndicator: View {
    var dotSize: CGFloat = 6
    var color: Color = .secondary
    var spacing: CGFloat = 4

    @State private var phase: Int = 0

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
        .accessibilityLabel(Text("AI is typing"))
    }

    private func startAnimating() {
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 350_000_000)
                phase = (phase + 1) % 3
            }
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        AITypingIndicator()
        AITypingIndicator(dotSize: 8, color: .accentColor, spacing: 6)
    }
    .padding()
}
