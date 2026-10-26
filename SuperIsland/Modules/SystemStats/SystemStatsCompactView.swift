import SwiftUI

struct SystemStatsCompactView: View {
    @ObservedObject private var manager = SystemStatsManager.shared

    var body: some View {
        HStack(spacing: 8) {
            // CPU
            HStack(spacing: 3) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(cpuColor)

                Text("\(Int(manager.cpuUsage))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            // RAM
            HStack(spacing: 3) {
                Image(systemName: "memorychip")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(ramColor)

                Text("\(Int(manager.ramPercent))%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }

            // Net Download
            HStack(spacing: 2) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(.cyan)

                Text(manager.downloadSpeedCompact)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
    }

    private var cpuColor: Color {
        if manager.cpuUsage >= 80 { return .red }
        if manager.cpuUsage >= 50 { return .orange }
        return .white.opacity(0.85)
    }

    private var ramColor: Color {
        if manager.ramPercent >= 85 { return .red }
        if manager.ramPercent >= 70 { return .orange }
        return .white.opacity(0.85)
    }
}
