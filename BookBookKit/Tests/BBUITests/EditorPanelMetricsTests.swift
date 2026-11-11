import Testing
@testable import BBUI

/// How the book window's panel cards share the width (`EditorPanelMetrics.fitted`).
struct EditorPanelMetricsTests {
    typealias M = EditorPanelMetrics

    @Test func storedWidthsFitInAWideWindow() {
        let fit = M.fitted(total: 1400, sidebar: 230, inspector: 400)
        #expect(fit.sidebar == 230)
        #expect(fit.inspector == 400)
    }

    @Test func storedWidthsAreClampedToTheirRanges() {
        let fit = M.fitted(total: 2000, sidebar: 10, inspector: 9000)
        #expect(fit.sidebar == M.sidebar.min)
        #expect(fit.inspector == M.inspector.max)
    }

    @Test func theInspectorGivesWayFirstThenTheSidebar() {
        // 900 pt: 280 + 460 + 320 + 40 = 1100, so 200 must go; the inspector can give 200.
        let narrow = M.fitted(total: 900, sidebar: 280, inspector: 460)
        #expect(narrow.inspector == 260)
        #expect(narrow.sidebar == 280)
        // At the window minimum both panels are at their minimums.
        let minimum = M.fitted(total: 780, sidebar: 280, inspector: 460)
        #expect(minimum.inspector == M.inspector.min)
        #expect(minimum.sidebar == M.sidebar.min)
    }

    @Test func withoutAnInspectorTheSidebarKeepsItsWidth() {
        let fit = M.fitted(total: 840, sidebar: 280, inspector: nil)
        #expect(fit.inspector == nil)
        #expect(fit.sidebar == 280)
    }
}
