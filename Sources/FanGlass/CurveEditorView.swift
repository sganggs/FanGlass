// CurveEditorView.swift — draggable fan curve editor.
// X axis: temperature (°C), Y axis: fan speed (% of RPM range, with RPM equivalents).
// Drag points · double-tap empty space to add · right-click a point to delete.
import SwiftUI

struct CurveEditorView: View {
    let points: [CurvePoint]
    /// nil when no trustworthy control temperature is available. Clamping a
    /// missing reading to the axis minimum would draw a working point at 25 °C
    /// that nothing on this Mac is actually reporting.
    let currentTemp: Double?
    let currentPercent: Double
    let minRPM: Double
    let maxRPM: Double
    let onCommit: ([CurvePoint]) -> Void

    private let tempRange: ClosedRange<Double> = 25...105
    private let maxPoints = 8

    @State private var draft: [CurvePoint] = []
    @State private var draggingID: UUID?
    @State private var selectedID: UUID?

    // layout
    private let labelLeft: CGFloat = 40
    private let labelBottom: CGFloat = 22
    private let labelTop: CGFloat = 8
    private let labelRight: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let plot = CGRect(
                x: labelLeft, y: labelTop,
                width: geo.size.width - labelLeft - labelRight,
                height: geo.size.height - labelTop - labelBottom
            )
            ZStack(alignment: .topLeading) {
                gridView(plot: plot)
                curveView(plot: plot)
                if let currentTemp {
                    currentTempMarker(plot: plot, temp: currentTemp)
                }
                pointsView(plot: plot)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { location in
                addPoint(at: location, plot: plot)
            }
            .onTapGesture(count: 1) { _ in selectedID = nil }
        }
        .onAppear { draft = sorted(points) }
        .onChange(of: points) { _, newValue in
            if draggingID == nil { draft = sorted(newValue) }
        }
    }

    // MARK: coordinate mapping

    private func sorted(_ pts: [CurvePoint]) -> [CurvePoint] {
        pts.sorted { $0.temp < $1.temp }
    }

    private func pointToView(_ p: CurvePoint, plot: CGRect) -> CGPoint {
        let x = plot.minX + CGFloat((p.temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * plot.width
        let y = plot.maxY - CGFloat(p.percent / 100) * plot.height
        return CGPoint(x: x, y: y)
    }

    private func viewToPoint(_ v: CGPoint, plot: CGRect) -> (temp: Double, percent: Double) {
        let t = Double((v.x - plot.minX) / plot.width) * (tempRange.upperBound - tempRange.lowerBound) + tempRange.lowerBound
        let p = Double((plot.maxY - v.y) / plot.height) * 100
        return (t, p)
    }

    // MARK: layers

    private func gridView(plot: CGRect) -> some View {
        Canvas { context, _ in
            // vertical lines every 10°C
            var temp = ceil(tempRange.lowerBound / 10) * 10
            while temp < tempRange.upperBound {
                let x = plot.minX + CGFloat((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * plot.width
                var path = Path()
                path.move(to: CGPoint(x: x, y: plot.minY))
                path.addLine(to: CGPoint(x: x, y: plot.maxY))
                context.stroke(path, with: .color(.secondary.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                let text = Text(String(format: "%.0f°", temp))
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                context.draw(context.resolve(text), at: CGPoint(x: x, y: plot.maxY + 11), anchor: .center)
                temp += 10
            }
            // horizontal lines every 25%
            for pct in stride(from: 0.0, through: 100.0, by: 25.0) {
                let y = plot.maxY - CGFloat(pct / 100) * plot.height
                var path = Path()
                path.move(to: CGPoint(x: plot.minX, y: y))
                path.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(path, with: .color(.secondary.opacity(0.14)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                let rpm = minRPM + pct / 100 * (maxRPM - minRPM)
                let text = Text(String(format: "%.0f", rpm))
                    .font(.system(size: 8.5))
                    .foregroundStyle(Color.secondary.opacity(0.8))
                context.draw(context.resolve(text), at: CGPoint(x: plot.minX - 6, y: y), anchor: .trailing)
            }
            // frame
            context.stroke(Path(plot), with: .color(.secondary.opacity(0.25)), lineWidth: 0.8)
        }
    }

    private func curvePath(plot: CGRect) -> Path {
        let pts = draft
        guard pts.count >= 2 else { return Path() }
        var path = Path()
        let samples = 120
        for i in 0...samples {
            let temp = tempRange.lowerBound + (tempRange.upperBound - tempRange.lowerBound) * Double(i) / Double(samples)
            let pct = CurveMath.evaluate(xs: pts.map(\.temp), ys: pts.map(\.percent), x: temp)
            let view = pointToView(CurvePoint(temp: temp, percent: pct), plot: plot)
            if i == 0 { path.move(to: view) } else { path.addLine(to: view) }
        }
        return path
    }

    private func filledCurvePath(plot: CGRect) -> Path {
        var path = curvePath(plot: plot)
        // curvePath is empty until .onAppear fills `draft`; addLine on a path
        // with no current point logs a CoreGraphics "no current point" error
        // on the first frame of every editor.
        guard !path.isEmpty else { return path }
        path.addLine(to: CGPoint(x: plot.maxX, y: plot.maxY))
        path.addLine(to: CGPoint(x: plot.minX, y: plot.maxY))
        path.closeSubpath()
        return path
    }

    private func curveView(plot: CGRect) -> some View {
        ZStack {
            filledCurvePath(plot: plot)
                .fill(
                    LinearGradient(colors: [GlassPalette.accent.opacity(0.22), GlassPalette.accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
            curvePath(plot: plot)
                .stroke(
                    LinearGradient(colors: [GlassPalette.accent, Color(red: 0.45, green: 0.35, blue: 0.95)],
                                   startPoint: .leading, endPoint: .trailing),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: GlassPalette.accent.opacity(0.4), radius: 4, x: 0, y: 2)
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: draft)
    }

    private func currentTempMarker(plot: CGRect, temp: Double) -> some View {
        let x = plot.minX + CGFloat((temp - tempRange.lowerBound) / (tempRange.upperBound - tempRange.lowerBound)) * plot.width
        let clampedX = min(max(x, plot.minX), plot.maxX)
        return ZStack {
            Path { path in
                path.move(to: CGPoint(x: clampedX, y: plot.minY))
                path.addLine(to: CGPoint(x: clampedX, y: plot.maxY))
            }
            .stroke(Color.orange.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, dash: [5, 4]))

            // actual operating point
            let op = pointToView(CurvePoint(temp: temp, percent: currentPercent), plot: plot)
            Circle()
                .fill(Color.orange)
                .frame(width: 9, height: 9)
                .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                .shadow(color: .orange.opacity(0.5), radius: 4)
                .position(x: min(max(op.x, plot.minX), plot.maxX),
                          y: min(max(op.y, plot.minY), plot.maxY))
        }
    }

    private func pointsView(plot: CGRect) -> some View {
        ForEach(draft) { point in
            let isSelected = selectedID == point.id
            let isDragging = draggingID == point.id
            Circle()
                .fill(isSelected ? Color.orange : Color.white)
                .frame(width: isDragging ? 16 : 13, height: isDragging ? 16 : 13)
                .overlay(
                    Circle()
                        .stroke(isSelected ? Color.orange : GlassPalette.accent, lineWidth: 2.2)
                )
                .shadow(color: (isSelected ? Color.orange : GlassPalette.accent).opacity(0.5),
                        radius: isDragging ? 7 : 4)
                .scaleEffect(isDragging ? 1.15 : 1)
                .animation(.spring(response: 0.25, dampingFraction: 0.6), value: isDragging)
                .position(pointToView(point, plot: plot))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            draggingID = point.id
                            selectedID = point.id
                            movePoint(id: point.id, to: value.location, plot: plot)
                        }
                        .onEnded { _ in
                            draggingID = nil
                            draft = sorted(draft)
                            onCommit(draft)
                        }
                )
                .contextMenu {
                    if draft.count > 2 {
                        Button("Delete point", role: .destructive) { deletePoint(id: point.id) }
                    }
                    Button(String(format: "%.0f°C · %.0f%%", point.temp, point.percent)) {}
                }
        }
    }

    // MARK: mutations

    private func movePoint(id: UUID, to location: CGPoint, plot: CGRect) {
        guard let idx = draft.firstIndex(where: { $0.id == id }) else { return }
        var (temp, percent) = viewToPoint(location, plot: plot)
        let ordered = sorted(draft)
        guard let orderIdx = ordered.firstIndex(where: { $0.id == id }) else { return }
        let lower = orderIdx > 0 ? ordered[orderIdx - 1].temp + 2 : tempRange.lowerBound
        let upper = orderIdx < ordered.count - 1 ? ordered[orderIdx + 1].temp - 2 : tempRange.upperBound
        temp = min(max(temp, lower), upper)
        percent = min(max(percent, 0), 100)
        draft[idx].temp = temp
        draft[idx].percent = percent
    }

    private func addPoint(at location: CGPoint, plot: CGRect) {
        guard draft.count < maxPoints, plot.insetBy(dx: -8, dy: -8).contains(location) else { return }
        var (temp, percent) = viewToPoint(location, plot: plot)
        temp = min(max(temp, tempRange.lowerBound + 1), tempRange.upperBound - 1)
        percent = min(max(percent, 0), 100)
        // Snap to the curve for a natural feel.
        let snapped = CurveMath.evaluate(xs: draft.map(\.temp), ys: draft.map(\.percent), x: temp)
        if abs(snapped - percent) < 12 { percent = snapped }
        draft.append(CurvePoint(temp: temp, percent: percent))
        draft = sorted(draft)
        onCommit(draft)
    }

    private func deletePoint(id: UUID) {
        guard draft.count > 2 else { return }
        draft.removeAll { $0.id == id }
        onCommit(draft)
    }
}
