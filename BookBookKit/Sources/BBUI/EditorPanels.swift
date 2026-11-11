import SwiftUI

/// The book window's "paper cards on a desk" layout: the sidebar, the detail area and the
/// optional inspector are rounded cards on a slightly darker desk, with a resize handle in each
/// gap. Replaces `NavigationSplitView` + `.inspector`: the panels can't be hidden or collapsed,
/// only resized within their ranges (widths are remembered across launches).
struct EditorPanels<Sidebar: View, Detail: View, Inspector: View>: View {
    var showsInspector: Bool
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail
    @ViewBuilder var inspector: Inspector

    @AppStorage("BookWindow.sidebarWidth") private var sidebarWidth: Double = EditorPanelMetrics.sidebar.ideal
    @AppStorage("BookWindow.inspectorWidth") private var inspectorWidth: Double = EditorPanelMetrics.inspector.ideal

    var body: some View {
        GeometryReader { proxy in
            let fit = EditorPanelMetrics.fitted(total: proxy.size.width, sidebar: sidebarWidth,
                                     inspector: showsInspector ? inspectorWidth : nil)
            HStack(spacing: 0) {
                sidebar
                    .crayonPanel(Crayon.card)
                    .frame(width: fit.sidebar)
                PanelResizeHandle(width: $sidebarWidth, current: fit.sidebar,
                                  range: EditorPanelMetrics.sidebar.min...EditorPanelMetrics.sidebar.max, growsRightward: true)
                detail
                    .crayonPanel(Crayon.paper)
                    .frame(maxWidth: .infinity)
                if showsInspector, let width = fit.inspector {
                    PanelResizeHandle(width: $inspectorWidth, current: width,
                                      range: EditorPanelMetrics.inspector.min...EditorPanelMetrics.inspector.max, growsRightward: false)
                    inspector
                        .crayonPanel(Crayon.card)
                        .frame(width: width)
                }
            }
            .padding(.horizontal, EditorPanelMetrics.gap)
            .padding(.vertical, EditorPanelMetrics.gap / 2)
            .padding(.bottom, EditorPanelMetrics.gap / 2)
        }
        .background(Crayon.desk.ignoresSafeArea())
    }
}

/// Panel widths in points. The window minimum (`BookWindow.minimumWidth`) fits both panels at
/// their minimums, the detail minimum and the gaps.
enum EditorPanelMetrics {
    static let sidebar = (min: 160.0, ideal: 210.0, max: 280.0)
    static let inspector = (min: 260.0, ideal: 320.0, max: 460.0)
    static let detailMin = 320.0
    /// The desk margin around the cards and the gap between them (where the handles sit).
    static let gap = 10.0

    /// The panel widths that fit `total`: each stored width clamped to its range, then the
    /// inspector and the sidebar give way (in that order) so the detail keeps its minimum.
    static func fitted(total: Double, sidebar stored: Double, inspector storedInspector: Double?)
        -> (sidebar: Double, inspector: Double?) {
        var side = stored.clamped(to: sidebar.min...sidebar.max)
        var insp = storedInspector.map { $0.clamped(to: inspector.min...inspector.max) }
        let gaps = gap * (insp == nil ? 3 : 4)
        var excess = side + (insp ?? 0) + detailMin + gaps - total
        if excess > 0, let current = insp {
            let give = min(excess, current - inspector.min)
            insp = current - give
            excess -= give
        }
        if excess > 0 { side -= min(excess, side - sidebar.min) }
        return (side, insp)
    }
}


extension View {
    /// A raised card on the desk: rounded, hairline-edged, with the crayon hard shadow.
    func crayonPanel(_ fill: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: Crayon.cornerRadius, style: .continuous)
        return self
            .frame(maxHeight: .infinity)
            .background(fill)
            .clipShape(shape)
            .overlay { shape.strokeBorder(Crayon.ink.opacity(0.08), lineWidth: 1) }
            .background { shape.fill(Crayon.shadow).offset(y: 3) }
    }
}

/// The grab strip in the gap between two cards. Dragging changes `width` (clamped to `range`);
/// a short grip shows on hover or while dragging.
private struct PanelResizeHandle: View {
    @Binding var width: Double
    /// The width on screen (after fitting to the window), where a drag starts from.
    var current: Double
    var range: ClosedRange<Double>
    /// Whether dragging right makes the panel wider (the sidebar) or narrower (the inspector).
    var growsRightward: Bool

    @State private var startWidth: Double?
    @State private var hovering = false

    var body: some View {
        Capsule()
            .fill(Crayon.ink.opacity(hovering || startWidth != nil ? 0.22 : 0))
            .frame(width: 3, height: 32)
            .frame(width: EditorPanelMetrics.gap)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .pointerStyle(.columnResize)
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? current
                        startWidth = start
                        let delta = growsRightward ? value.translation.width : -value.translation.width
                        width = (start + delta).clamped(to: range)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .accessibilityHidden(true)
    }
}

extension Double {
    fileprivate func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
