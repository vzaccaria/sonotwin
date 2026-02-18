import SwiftUI

/// VU meter with gradient bar and peak indicator
struct VUMeterView: View {
    let level: Float      // 0.0 to 1.0 (normalized from dB)
    let peak: Float       // 0.0 to 1.0 (normalized from dB)
    let label: String
    let isEnabled: Bool

    init(level: Float, peak: Float, label: String, isEnabled: Bool = true) {
        self.level = level
        self.peak = peak
        self.label = label
        self.isEnabled = isEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundColor(isEnabled ? .primary : .secondary)

            GeometryReader { geometry in
                let width = geometry.size.width
                let height: CGFloat = 12

                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.2))

                    // Level gradient bar
                    if isEnabled {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [.green, .green, .yellow, .orange, .red],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(width: max(0, width * CGFloat(level)))
                            .animation(.linear(duration: 0.05), value: level)

                        // Peak indicator
                        if peak > 0.01 {
                            Rectangle()
                                .fill(peakColor(peak))
                                .frame(width: 2)
                                .offset(x: max(0, width * CGFloat(peak) - 2))
                                .animation(.linear(duration: 0.05), value: peak)
                        }
                    }
                }
                .frame(height: height)
            }
            .frame(height: 12)

            // dB scale
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
            .font(.system(size: 8))
            .foregroundColor(.secondary)
        }
        .opacity(isEnabled ? 1.0 : 0.5)
    }

    private func peakColor(_ peak: Float) -> Color {
        if peak > 0.9 {
            return .red
        } else if peak > 0.7 {
            return .orange
        } else {
            return .white
        }
    }
}
