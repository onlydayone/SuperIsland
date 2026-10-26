import SwiftUI

struct SystemStatsExpandedView: View {
    @ObservedObject private var manager = SystemStatsManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.cyan)

                VStack(alignment: .leading, spacing: 1) {
                    Text("System Monitor")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)

                    if !manager.hardwareSummary.isEmpty {
                        Text(manager.hardwareSummary)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.52))
                    }
                }

                Spacer()

                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.cyan)
                        Text(manager.downloadSpeedFormatted)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.orange)
                        Text(manager.uploadSpeedFormatted)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                    }
                }
            }

            // Gauges Row
            HStack(spacing: 14) {
                // CPU Metric Card
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("CPU")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text("\(Int(manager.cpuUsage))%")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundColor(cpuColor)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(cpuColor)
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, manager.cpuUsage / 100.0))))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )

                // RAM Metric Card
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("RAM")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white.opacity(0.6))
                        Spacer()
                        Text(String(format: "%.1f / %.0f GB (%d%%)", manager.ramUsedGB, manager.ramTotalGB, Int(manager.ramPercent)))
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundColor(ramColor)
                    }

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color.white.opacity(0.1))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(ramColor)
                                .frame(width: geo.size.width * CGFloat(min(1.0, max(0.0, manager.ramPercent / 100.0))))
                        }
                    }
                    .frame(height: 6)
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }

            // CPU Trend Sparkline
            if manager.cpuHistory.count >= 2 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("CPU Trend")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))

                    SystemStatsSparkline(samples: manager.cpuHistory, color: .cyan)
                        .frame(height: 32)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var cpuColor: Color {
        if manager.cpuUsage >= 80 { return .red }
        if manager.cpuUsage >= 50 { return .orange }
        return .cyan
    }

    private var ramColor: Color {
        if manager.ramPercent >= 85 { return .red }
        if manager.ramPercent >= 70 { return .orange }
        return .purple
    }
}

private struct SystemStatsSparkline: View {
    let samples: [Double]
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            let points = normalizedPoints(in: proxy.size)
            ZStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.white.opacity(0.04))

                if points.count >= 2 {
                    areaPath(points: points, in: proxy.size)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.25), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    linePath(points: points)
                        .stroke(color.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))

                    if let last = points.last {
                        Circle()
                            .fill(color)
                            .frame(width: 4, height: 4)
                            .position(last)
                    }
                }
            }
        }
    }

    private func normalizedPoints(in size: CGSize) -> [CGPoint] {
        guard samples.count >= 2 else { return [] }
        let maxVal = max(100.0, (samples.max() ?? 100.0))
        let minVal = 0.0
        let range = max(1.0, maxVal - minVal)

        let stepX = size.width / CGFloat(samples.count - 1)
        return samples.enumerated().map { index, val in
            let normY = (val - minVal) / range
            let x = CGFloat(index) * stepX
            let y = size.height - (CGFloat(normY) * (size.height - 4) + 2)
            return CGPoint(x: x, y: y)
        }
    }

    private func linePath(points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for pt in points.dropFirst() {
            path.addLine(to: pt)
        }
        return path
    }

    private func areaPath(points: [CGPoint], in size: CGSize) -> Path {
        var path = linePath(points: points)
        guard let last = points.last, let first = points.first else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }
}
