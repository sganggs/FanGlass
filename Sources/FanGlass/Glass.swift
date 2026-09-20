// Glass.swift — liquid glass component library.
// Design language (solid-background edition):
//   The glass lives in the EDGES, not the background. A calm solid base color,
//   one static white "studio light" at the top, and every glass surface answers
//   that light with a specular top line, gradient hairline border and layered
//   shadows — the same recipe as macOS Tahoe / visionOS / CleanMyMac X.
import SwiftUI

// MARK: - palette

enum GlassPalette {
    /// 0 = cool … 1 = hot
    static func heatColor(_ h: Double) -> Color {
        let h = max(0, min(1, h))
        if h < 0.33 {
            return Color(red: 0.25, green: 0.65, blue: 1.0).opacity(1 - (0.33 - h))
        } else if h < 0.66 {
            return Color(red: 0.30, green: 0.85, blue: 0.65)
        } else if h < 0.85 {
            return Color(red: 1.0, green: 0.70, blue: 0.30)
        }
        return Color(red: 0.98, green: 0.35, blue: 0.30)
    }

    static let accent = Color(red: 0.25, green: 0.62, blue: 1.0)

    /// `accent` for TEXT. The fill colour is ≈2.8:1 on a white glass chip —
    /// below the 4.5:1 floor, and the selected state is precisely what has to be
    /// readable at a glance. This darker blue is ≈4.7:1 on the same chip.
    static let accentInk = Color(red: 0.0, green: 0.35, blue: 0.78)
}

// MARK: - solid background (static studio light + ambient heat strip)

struct SolidBackground: View {
    /// 0...1, derived from the hottest sensor.
    var heat: Double
    /// The ambient status strip can be disabled when the top bar renders its own.
    var showStrip: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            // Base: reads as a solid color, with a ±2% vertical lightness drift
            // so the window isn't dead-flat (Raycast/Linear trick).
            LinearGradient(
                colors: [
                    Color(red: 0.953, green: 0.961, blue: 0.976),
                    Color(red: 0.925, green: 0.936, blue: 0.957),
                ],
                startPoint: .top, endPoint: .bottom
            )

            // One static white studio light at the top edge. Static on purpose:
            // moving colored light is what made the old background feel cheap.
            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.55), Color.white.opacity(0)],
                        center: .center, startRadius: 0, endRadius: 240
                    )
                )
                .frame(width: 720, height: 240)
                .offset(y: -120)

            if showStrip {
                AmbientHeatStrip(heat: heat)
            }
        }
    }
}

/// Thin status light bar: the only place temperature still "colors" the chrome.
struct AmbientHeatStrip: View {
    var heat: Double

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            GlassPalette.heatColor(heat).opacity(0),
                            GlassPalette.heatColor(heat).opacity(0.65),
                            GlassPalette.heatColor(heat).opacity(0),
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                )
                .frame(height: 2.5)
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [GlassPalette.heatColor(heat).opacity(0.18),
                                 GlassPalette.heatColor(heat).opacity(0)],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .frame(height: 26)
                .blur(radius: 8)
        }
        .animation(.easeOut(duration: 0.8), value: heat)
    }
}

// MARK: - glass card (edge-driven glass on solid background)

struct GlassCard<Content: View>: View {
    var padding: CGFloat = 16
    var cornerRadius: CGFloat = 18
    @ViewBuilder var content: Content

    @State private var hovering = false

    var body: some View {
        content
            .padding(padding)
            .background {
                ZStack(alignment: .top) {
                    // 1 · main fill: nearly-opaque white, keeps a hint of translucency
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(Color.white.opacity(hovering ? 0.72 : 0.62))

                    // 2 · specular light from the studio lamp (top-biased gradient)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.28), Color.white.opacity(0.03)],
                                startPoint: .top, endPoint: .center
                            )
                        )

                    // 3 · hairline border, brighter where the light hits,
                    //     darkening at the very bottom to ground the card
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(hovering ? 0.95 : 0.80),
                                    Color.white.opacity(0.25),
                                    Color.black.opacity(0.05),
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 1
                        )

                    // 4 · the signature specular top line, fading at both ends
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [.clear, Color.white.opacity(hovering ? 1.0 : 0.9), .clear],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .frame(height: 1)
                        .padding(.horizontal, cornerRadius * 1.4)
                }
                // 5 · single soft shadow — stacking a hard contact shadow under a
                //     soft one produced a visible "step" on white cards
                .shadow(color: Color.black.opacity(hovering ? 0.12 : 0.08),
                        radius: hovering ? 18 : 14, x: 0, y: hovering ? 7 : 5)
            }
            .scaleEffect(hovering ? 1.006 : 1)
            .animation(.spring(response: 0.35, dampingFraction: 0.7), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - glass button style (springy press + hover)

struct LiquidButtonStyle: ButtonStyle {
    var prominent: Bool = false
    /// Tighter padding, for the menu-bar popover's quick-mode pills. Its
    /// metrics (12 pt type, 8 pt of horizontal padding a side) are what
    /// `AdaptivePillRow` measures against the panel's 296-pt content box.
    var compact: Bool = false
    /// Marks this button as the option currently in effect. The signal lives in
    /// the hairline and the label weight, not in a heavy fill — "glass at the
    /// edges" — so it stays clearly distinct from `prominent`.
    var active: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        LiquidButtonBody(prominent: prominent, compact: compact, active: active,
                         configuration: configuration)
    }

    private struct LiquidButtonBody: View {
        let prominent: Bool
        let compact: Bool
        let active: Bool
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        /// A button that becomes disabled under the cursor gets no onHover(false),
        /// so `hovering` would stay stuck true. Gate every hover visual on this.
        private var isHovering: Bool { isEnabled && hovering }

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 12 : 13, weight: active ? .semibold : .medium))
                .lineLimit(1)
                .padding(.horizontal, compact ? 8 : 14)
                .padding(.vertical, compact ? 5 : 7)
                .frame(maxWidth: compact ? .infinity : nil)
                .foregroundStyle(prominent ? Color.white : (active ? GlassPalette.accentInk : Color.primary))
                .background {
                    ZStack(alignment: .top) {
                        Capsule(style: .continuous)
                            .fill(baseFill)
                        // Tint the glass instead of replacing it. Filling the
                        // active pill with accent @0.14 alone left the SELECTED
                        // chip dimmer than its white @0.6 neighbours — in a row
                        // of five it read as the recessed one, which inverts the
                        // hierarchy the highlight exists to establish.
                        if active && !prominent {
                            Capsule(style: .continuous)
                                .fill(GlassPalette.accent.opacity(isHovering ? 0.26 : 0.20))
                        }
                        Capsule(style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(prominent ? 0.35 : 0.4),
                                             Color.white.opacity(0.02)],
                                    startPoint: .top, endPoint: .center
                                )
                            )
                        Capsule(style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: active
                                        ? [GlassPalette.accent.opacity(0.9), GlassPalette.accent.opacity(0.35)]
                                        : [Color.white.opacity(0.85), Color.white.opacity(0.2)],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: active ? 1.2 : 0.8
                            )
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [.clear, Color.white.opacity(prominent ? 0.8 : 0.9), .clear],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .frame(height: 1)
                            .padding(.horizontal, compact ? 6 : 10)
                    }
                    .shadow(color: shadowColor, radius: isHovering ? 7 : 4, x: 0, y: 2)
                }
                // Disabled buttons must stop reading as clickable: dim them and
                // freeze the hover lift / press bounce.
                .opacity(isEnabled ? 1 : 0.45)
                .scaleEffect(isEnabled ? (configuration.isPressed ? 0.94 : (hovering ? 1.04 : 1)) : 1)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isEnabled)
                .brightness(configuration.isPressed ? -0.03 : 0)
                .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
                .animation(.easeOut(duration: 0.2), value: active)
                .onHover { hovering = $0 }
                // Not colour-only: weight and border change too, and VoiceOver
                // gets the selection explicitly.
                .accessibilityAddTraits(active ? [.isSelected] : [])
        }

        private var baseFill: AnyShapeStyle {
            if prominent { return AnyShapeStyle(GlassPalette.accent.gradient) }
            // The active pill keeps the white glass body (and is a touch
            // brighter than the inactive ones); the accent arrives as a tint
            // layer above it, not as a replacement.
            if active { return AnyShapeStyle(Color.white.opacity(isHovering ? 0.78 : 0.68)) }
            return AnyShapeStyle(Color.white.opacity(isHovering ? 0.75 : 0.6))
        }

        private var shadowColor: Color {
            if prominent { return GlassPalette.accent.opacity(0.35) }
            if active { return GlassPalette.accent.opacity(0.28) }
            return Color.black.opacity(0.07)
        }
    }
}

// MARK: - adaptive pill row (equal width while it fits, wrapping when it does not)

/// Lays a row of pills out the way the menu-bar panel always has — one row of
/// equal-width pills — for as long as the WIDEST label fits its share, and
/// wraps onto further rows at each pill's natural width when it does not.
///
/// The panel's content box is 296 pt (328 − 2×16 padding). Five 2-character
/// Simplified Chinese labels need 40 pt each against a 55.2 pt share, so they
/// still get the single equal-width row. Their English counterparts do not:
/// "Performance" alone measures 93 pt at 12 pt semibold + 16 pt padding, five
/// equal columns would want 485 pt, and every label would truncate to "…".
/// Wrapping is the honest answer — shrinking the type or the panel is not.
struct AdaptivePillRow: Layout {
    var spacing: CGFloat = 5

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        plan(subviews: subviews, width: proposal.width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout Void) {
        let plan = plan(subviews: subviews, width: bounds.width)
        var y = bounds.minY
        for row in plan.rows {
            var x = bounds.minX
            for index in row {
                let width = plan.widths[index]
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: width, height: plan.rowHeight)
                )
                x += width + spacing
            }
            y += plan.rowHeight + spacing
        }
    }

    private struct Plan {
        var rows: [[Int]] = []       // subview indexes, in order
        var widths: [CGFloat] = []   // width each subview is placed at
        var rowHeight: CGFloat = 0
        var size: CGSize = .zero
    }

    private func plan(subviews: Subviews, width: CGFloat?) -> Plan {
        var plan = Plan()
        guard !subviews.isEmpty else { return plan }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let widths = sizes.map(\.width)
        let count = subviews.count
        let n = CGFloat(count)
        let gaps = spacing * (n - 1)
        let widest = widths.max() ?? 0
        plan.rowHeight = sizes.map(\.height).max() ?? 0

        // Measurement passes propose zero or infinity; answer with the natural
        // one-row size rather than "every pill on its own row".
        guard let available = width, available.isFinite, available > 0 else {
            plan.rows = [Array(subviews.indices)]
            plan.widths = Array(repeating: widest, count: count)
            plan.size = CGSize(width: widest * n + gaps, height: plan.rowHeight)
            return plan
        }

        if widest * n + gaps <= available {
            let each = (available - gaps) / n
            plan.rows = [Array(subviews.indices)]
            plan.widths = Array(repeating: each, count: count)
            plan.size = CGSize(width: available, height: plan.rowHeight)
            return plan
        }

        // Fewest rows that fit, then spread the pills evenly across them: a
        // plain greedy fill packs four English labels into the first row and
        // leaves "Max" orphaned under them.
        plan.widths = widths
        let minimum = pack(widths, available: available, cap: count).count
        let cap = Int((Double(count) / Double(minimum)).rounded(.up))
        var rows = pack(widths, available: available, cap: cap)
        if rows.count > minimum { rows = pack(widths, available: available, cap: count) }
        plan.rows = rows
        plan.size = CGSize(
            width: available,
            height: CGFloat(rows.count) * plan.rowHeight + CGFloat(rows.count - 1) * spacing
        )
        return plan
    }

    /// Left-to-right fill, breaking when the next pill would overflow the row
    /// or when the row already holds `cap` of them.
    private func pack(_ widths: [CGFloat], available: CGFloat, cap: Int) -> [[Int]] {
        var rows: [[Int]] = [[]]
        var used: CGFloat = 0
        for (index, width) in widths.enumerated() {
            let last = rows.count - 1
            if rows[last].isEmpty {
                rows[last].append(index)
                used = width
                continue
            }
            let extended = used + spacing + width
            if extended > available || rows[last].count >= cap {
                rows.append([index])
                used = width
            } else {
                rows[last].append(index)
                used = extended
            }
        }
        return rows
    }
}

// MARK: - liquid segmented control (glass pill glides between options)

struct LiquidSegmentedPicker<Selection: Hashable>: View {
    let options: [(value: Selection, title: String)]
    @Binding var selection: Selection
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { option in
                Button {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: selection == option.value ? .semibold : .regular))
                        .foregroundStyle(selection == option.value ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background {
                            if selection == option.value {
                                Capsule(style: .continuous)
                                    .fill(Color.white.opacity(0.85))
                                    .overlay {
                                        Capsule(style: .continuous)
                                            .strokeBorder(
                                                LinearGradient(
                                                    colors: [Color.white.opacity(0.95), Color.white.opacity(0.3)],
                                                    startPoint: .top, endPoint: .bottom
                                                ),
                                                lineWidth: 0.8
                                            )
                                    }
                                    .shadow(color: Color.black.opacity(0.10), radius: 4, x: 0, y: 1.5)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            } else {
                                // Unselected tabs have no fill; without a shape,
                                // SwiftUI only hit-tests the glyphs.
                                Capsule(style: .continuous).fill(Color.clear)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .contentShape(Capsule())
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.35))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8)
                }
        }
    }
}

// MARK: - real AppKit blur (for the unified top bar)

/// NSVisualEffectView wrapper. `.withinWindow` blending blurs the window's own
/// content behind the bar (scrolling cards), unlike SwiftUI materials which
/// read flat white on a light background.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

// MARK: - glass scroll view (custom floating glass thumb, native scroller removed)

struct GlassScrollView<Content: View>: View {
    var topMargin: CGFloat = 0
    /// Side/bottom insets live INSIDE the scroll view (content margins), not
    /// outside it: the scroll view clips at its bounds, and an outer padding
    /// used to place that clip line 20 pt into the background where it sliced
    /// card shadows off mid-air (visible "seam", worst on hover).
    var horizontalMargin: CGFloat = 20
    var bottomMargin: CGFloat = 16
    var onScrolled: ((Bool) -> Void)? = nil
    @ViewBuilder var content: Content

    @State private var contentHeight: CGFloat = 1
    @State private var containerHeight: CGFloat = 1
    @State private var scrollOffset: CGFloat = 0
    @State private var scrollPosition = ScrollPosition(edge: .top)
    @State private var scrolling = false
    @State private var hovering = false
    @State private var trackHover = false
    @State private var dragging = false
    @State private var dragAnchor: CGFloat?
    @State private var dragAnchorY: CGFloat = 0
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollPosition($scrollPosition)
        .scrollIndicators(.hidden)
        .contentMargins(.top, topMargin, for: .scrollContent)
        .contentMargins(.horizontal, horizontalMargin, for: .scrollContent)
        .contentMargins(.bottom, bottomMargin, for: .scrollContent)
        .onAppear {
            // Screenshot/debug hook: pre-scroll the view to exercise the
            // under-top-bar blur, separator and thumb states.
            if CommandLine.arguments.contains("--debug-scrolled") {
                scrollPosition.scrollTo(y: 150)
            }
        }
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geo in
            scrollOffset = geo.contentOffset.y + geo.contentInsets.top
            containerHeight = max(geo.containerSize.height, 1)
            contentHeight = max(geo.contentSize.height + geo.contentInsets.top + geo.contentInsets.bottom, 1)
            onScrolled?(scrollOffset > 4)
            revealThumb()
        }
        .onHover { hovering = $0 }
        .overlay(alignment: .topTrailing) {
            if contentHeight > containerHeight + 1 {
                // Track starts below the top bar and ends above the bottom
                // margin, like native overlay scrollers do. The track itself is
                // ALWAYS hit-testable (the visible thumb comes and goes), so the
                // scroller can be grabbed like a native one: drag the thumb to
                // scroll, click/drag the empty track to jump there.
                let trackTop = topMargin + 5
                let trackH = max(containerHeight - trackTop - bottomMargin - 10, 1)
                let thumbH = max(30, trackH * containerHeight / contentHeight)
                let maxOffset = max(contentHeight - containerHeight, 1)
                let progress = min(max(scrollOffset / maxOffset, 0), 1)
                ZStack(alignment: .top) {
                    // AppKit track: a SwiftUI DragGesture here LOSES to
                    // isMovableByWindowBackground (the window starts moving on
                    // mouseDown before the gesture is recognized); an NSView
                    // overriding mouseDownCanMoveWindow wins deterministically.
                    ScrollerTrack(
                        began: { y in
                            let travel = trackH - thumbH
                            guard travel > 0 else { return }
                            let currentProgress = min(max(scrollOffset / maxOffset, 0), 1)
                            let thumbTop = travel * currentProgress
                            dragging = true
                            dragAnchorY = y
                            if y < thumbTop || y > thumbTop + thumbH {
                                // grabbed empty track: jump the thumb under the cursor
                                let p = min(max((y - thumbH / 2) / travel, 0), 1)
                                dragAnchor = p
                                scrollPosition.scrollTo(y: p * maxOffset)
                            } else {
                                dragAnchor = currentProgress
                            }
                        },
                        moved: { y in
                            let travel = trackH - thumbH
                            guard travel > 0, let anchor = dragAnchor else { return }
                            let target = min(max(anchor + (y - dragAnchorY) / travel, 0), 1)
                            scrollPosition.scrollTo(y: target * maxOffset)
                        },
                        ended: {
                            dragAnchor = nil
                            dragging = false
                            revealThumb()
                        },
                        hover: { trackHover = $0 }
                    )
                    Capsule()
                        .fill(Color.white.opacity(0.95))
                        .overlay {
                            Capsule()
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [Color.white.opacity(1.0), Color.black.opacity(0.10)],
                                        startPoint: .top, endPoint: .bottom
                                    ),
                                    lineWidth: 0.8
                                )
                        }
                        .shadow(color: Color.black.opacity(0.14), radius: 4, x: 0, y: 1)
                        .frame(width: dragging ? 8 : 6, height: thumbH)
                        .offset(y: (trackH - thumbH) * progress)
                        .opacity(scrolling || hovering || dragging || trackHover ? 1 : 0)
                        .animation(.easeOut(duration: 0.25), value: scrolling)
                        .animation(.easeOut(duration: 0.25), value: hovering)
                        .animation(.easeOut(duration: 0.15), value: dragging)
                        .allowsHitTesting(false)
                }
                .frame(width: 14, height: trackH)
                .padding(.top, trackTop)
                .padding(.trailing, 1)
            }
        }
    }

    private func revealThumb() {
        if !scrolling { scrolling = true }
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, !dragging else { return }
            withAnimation(.easeOut(duration: 0.5)) { scrolling = false }
        }
    }
}

/// AppKit-backed scroller track. Exists because the window uses
/// isMovableByWindowBackground: a plain SwiftUI DragGesture on the track never
/// fires (AppKit starts moving the window on mouseDown), while an NSView that
/// overrides mouseDownCanMoveWindow=false receives the full drag itself.
/// Flipped so local y is top-down, matching the SwiftUI-side thumb math.
private struct ScrollerTrack: NSViewRepresentable {
    var began: (CGFloat) -> Void
    var moved: (CGFloat) -> Void
    var ended: () -> Void
    var hover: (Bool) -> Void

    func makeNSView(context: Context) -> TrackView {
        let view = TrackView()
        update(view)
        return view
    }

    func updateNSView(_ view: TrackView, context: Context) { update(view) }

    private func update(_ view: TrackView) {
        view.began = began
        view.moved = moved
        view.ended = ended
        view.hover = hover
    }

    final class TrackView: NSView {
        var began: ((CGFloat) -> Void)?
        var moved: ((CGFloat) -> Void)?
        var ended: (() -> Void)?
        var hover: ((Bool) -> Void)?

        override var isFlipped: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow],
                owner: self
            ))
        }

        override func mouseEntered(with event: NSEvent) { hover?(true) }
        override func mouseExited(with event: NSEvent) { hover?(false) }
        override func mouseDown(with event: NSEvent) {
            began?(convert(event.locationInWindow, from: nil).y)
        }
        override func mouseDragged(with event: NSEvent) {
            moved?(convert(event.locationInWindow, from: nil).y)
        }
        override func mouseUp(with event: NSEvent) { ended?() }
    }
}

// MARK: - sparkline

struct Sparkline: View {
    var values: [Double]
    var color: Color
    var lineWidth: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            guard values.count > 1,
                  let minV = values.min(), let maxV = values.max(), maxV > minV else { return }
            let stepX = size.width / CGFloat(values.count - 1)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = CGFloat(i) * stepX
                let y = size.height - (CGFloat(v - minV) / CGFloat(maxV - minV)) * (size.height - 4) - 2
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
                else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), lineWidth: lineWidth)

            var fillPath = path
            fillPath.addLine(to: CGPoint(x: size.width, y: size.height))
            fillPath.addLine(to: CGPoint(x: 0, y: size.height))
            fillPath.closeSubpath()
            context.fill(fillPath, with: .linearGradient(
                Gradient(colors: [color.opacity(0.25), color.opacity(0)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)
            ))
        }
    }
}

// MARK: - spinning fan glyph (angular speed follows real RPM, visually damped)

struct SpinningFanView: View {
    var rpm: Double
    var size: CGFloat = 15
    var color: Color = GlassPalette.accent

    @State private var angle: Double = 0
    @State private var lastDate: Date?

    var body: some View {
        // Paused at rest: a stopped fan's glyph is visually static, but an
        // unpaused TimelineView still redraws it 30x a second for as long as
        // the window is open — in an app whose job is power and thermals.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0, paused: rpm <= 0)) { timeline in
            Image(systemName: "fan.fill")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .rotationEffect(.degrees(angle))
                .onChange(of: timeline.date) { _, newDate in
                    if let last = lastDate {
                        // Capped: coming back from paused (or an occluded
                        // window) hands us the whole gap as one step.
                        let dt = min(newDate.timeIntervalSince(last), 0.1)
                        // visually damped: 1000 RPM ≈ 0.8 rev/s, 4900 RPM ≈ 4 rev/s
                        angle = (angle + rpm * dt * 0.05 * 360 / 60).truncatingRemainder(dividingBy: 360)
                    }
                    lastDate = newDate
                }
        }
    }
}

// MARK: - section label

struct GlassSectionHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
            Spacer()
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}
