import SwiftUI

// MARK: - VUMeterView
// A visual meter showing audio levels with a gradient bar and peak indicator.
//
// SwiftUI views are structs (value types) that describe what to display.
// When any of the input properties change, SwiftUI automatically redraws the view.
// This is called "declarative UI" - you describe what you want, not how to draw it.

struct VUMeterView: View {

    // MARK: - Properties
    // These are the inputs to the view. When they change, the view updates.
    // 'let' means they're immutable - set once when the view is created.

    let level: Float      // Current RMS level (0.0 to 1.0, normalized from dB)
    let peak: Float       // Current peak level (0.0 to 1.0, normalized from dB)
    let label: String     // Label text (e.g., "System Audio")
    let isEnabled: Bool   // Whether this source is being recorded

    // MARK: - Initializer
    // Custom init with default value for isEnabled.
    // This makes calling VUMeterView(level: 0.5, peak: 0.6, label: "Mic") work.

    init(level: Float, peak: Float, label: String, isEnabled: Bool = true) {
        self.level = level
        self.peak = peak
        self.label = label
        self.isEnabled = isEnabled
    }

    // MARK: - Body
    // The 'body' property is required by the View protocol.
    // It returns the view hierarchy to display.
    // 'some View' means "returns something conforming to View" (opaque return type).

    var body: some View {
        // VStack arranges children vertically.
        // alignment: .leading means left-aligned (for left-to-right languages).
        // spacing: 4 means 4 points between each child.
        VStack(alignment: .leading, spacing: 4) {

            // MARK: Label
            Text(label)
                .font(.caption)  // Small text size
                .foregroundColor(isEnabled ? .primary : .secondary)  // Dimmed when disabled

            // MARK: Meter Bar
            // GeometryReader gives us the actual size of the available space.
            // This is how we make the bar fill the available width.
            GeometryReader { geometry in
                let width = geometry.size.width
                let height: CGFloat = 12

                // ZStack layers children on top of each other (back to front).
                // alignment: .leading means they all start from the left edge.
                ZStack(alignment: .leading) {

                    // Background (gray rectangle)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))

                    // Level gradient bar (only shown when enabled)
                    if isEnabled {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                // LinearGradient transitions between colors.
                                // Green on left → yellow → orange → red on right.
                                LinearGradient(
                                    colors: [.green, .green, .yellow, .orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            // Width is proportional to level (0-1 maps to 0-full width).
                            .frame(width: max(0, width * CGFloat(level)))
                            // Animate changes smoothly over 50ms.
                            .animation(.linear(duration: 0.05), value: level)

                        // Peak indicator (thin white/colored line)
                        if peak > 0.01 {
                            Rectangle()
                                .fill(peakColor(peak))
                                .frame(width: 2)
                                // Position at the peak level.
                                .offset(x: max(0, width * CGFloat(peak) - 2))
                                .animation(.linear(duration: 0.05), value: peak)
                        }
                    }
                }
                .frame(height: height)
            }
            .frame(height: 12)  // Fixed height for the meter

            // MARK: dB Scale Labels
            // HStack arranges children horizontally.
            // Spacer() pushes siblings apart, creating even distribution.
            HStack {
                Text("-60")
                Spacer()
                Text("-40")
                Spacer()
                Text("-20")
                Spacer()
                Text("-6")
                Spacer()
                Text("0 dB")
            }
            .font(.system(size: 8))  // Very small text
            .foregroundColor(.secondary)  // Gray color
        }
        // Dim the entire meter when disabled.
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    // MARK: - Helper Functions

    /// Returns color for peak indicator based on level.
    /// Red when clipping (>90%), orange when hot (>70%), white otherwise.
    private func peakColor(_ peak: Float) -> Color {
        if peak > 0.9 {
            return .red     // Clipping danger!
        } else if peak > 0.7 {
            return .orange  // Getting hot
        } else {
            return .white   // Normal
        }
    }
}
