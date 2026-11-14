import BBAI
import BBModel
import Foundation
import Testing
@testable import BBUI

@Suite struct ConsistencyUITests {
    private static let ref = ImageRef(sha256: String(repeating: "ab", count: 32), contentType: "public.png")

    private func report(_ differences: [ConsistencyDifference], warns: Bool = true, dismissed: Bool = false) -> ConsistencyReport {
        ConsistencyReport(checkedAt: Date(timeIntervalSince1970: 0), provider: .openai, model: "gpt-6.1-terra",
                          consistent: differences.isEmpty, differences: differences, warns: warns, dismissed: dismissed,
                          sent: ConsistencySent(promptSent: "Compare these.",
                                                imagesSent: [SentReference(image: Self.ref, role: "checked", label: "Checked image")],
                                                parametersSent: ["detail": "low", "store": "false"]))
    }

    private let minor = ConsistencyDifference(asset: "Pip", aspect: "scarf", observed: "blue", expected: "red", severity: .minor)
    private let major = ConsistencyDifference(asset: nil, aspect: "palette", observed: "neon", expected: "pastel", severity: .major)

    @Test func differenceLinesListMajorFirst() {
        let lines = ConsistencyPresentation.lines(report([minor, major]))
        #expect(lines == ["palette: neon; reference is pastel", "Pip — scarf: blue; reference is red"])
    }

    @Test func resultText() {
        #expect(ConsistencyPresentation.resultText(report([], warns: false)) == "Consistent with the references")
        #expect(ConsistencyPresentation.resultText(report([minor, major])) == "Differences found (1 major, 1 minor)")
        #expect(ConsistencyPresentation.resultText(report([minor], dismissed: true))
            == "Differences found (1 minor), warning dismissed")
    }

    @Test func unavailableReasonOrder() {
        func reason(canCheck: Bool = true, editable: Bool = true, online: Bool = true, key: Bool = true,
                    pending: Bool = false) -> String? {
            ConsistencyPresentation.checkUnavailableReason(canCheck: canCheck, isEditable: editable, isOnline: online,
                                                           hasKey: key, isPending: pending)
        }
        #expect(reason() == nil)
        #expect(reason(editable: false) != nil)
        #expect(reason(pending: true) != nil)
        #expect(reason(canCheck: false) != nil)
        #expect(reason(online: false) != nil)
        #expect(reason(key: false) != nil)
    }

    @Test func detailsShowEverythingSent() {
        let version = Version(image: Self.ref, pixelSize: PixelSize(width: 10, height: 10), source: .imported,
                              createdAt: Date(timeIntervalSince1970: 0), consistency: report([minor]))
        let rows = VersionDetailsContent.rows(for: version, dateFormatter: { _ in "D" })
        let labels = rows.map(\.label)
        for expected in ["Check model", "Checked", "Check result", "Differences", "Check prompt sent",
                         "Check images sent", "Check parameters sent", "Check cost"] {
            #expect(labels.contains(expected), "missing \(expected)")
        }
        #expect(rows.first { $0.label == "Check images sent" }?.value == "Checked image (checked)")
    }

    @Test func noConsistencyRowsWithoutAReport() {
        let version = Version(image: Self.ref, pixelSize: PixelSize(width: 10, height: 10), source: .imported,
                              createdAt: Date())
        #expect(!VersionDetailsContent.rows(for: version).contains { $0.label.hasPrefix("Check") })
    }

    @Test func consistencyFlagShowsInFlagText() {
        let entries = FlagText.entries([.consistencyWarning])
        #expect(entries.map(\.title) == ["Consistency warning"])
        #expect(FlagText.summary([.styleChanged, .consistencyWarning]) == "Style changed, Consistency warning")
    }

    @Test func runningCheckSaysChecking() {
        let now = Date()
        let running = QueueItemState.running(startedAt: now, progress: nil, attempt: 1)
        #expect(QueueRowModel.stateText(running, now: now, typical: nil, headline: nil, isConsistencyCheck: true)
            .hasPrefix("Checking consistency…"))
        #expect(QueueRowModel.stateText(running, now: now, typical: nil, headline: nil).hasPrefix("Generating…"))
    }

    @MainActor @Test func settingsKeysPersist() throws {
        let suite = "ConsistencyUITests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = AppPreferences(defaults: defaults, fallbackModelID: "img")
        #expect(prefs.consistencyCheckEnabled)
        prefs.consistencyCheckEnabled = false
        prefs.defaultTemplateModelID = "tmpl-x"
        prefs.defaultConsistencyModelID = "vis-y"
        let reloaded = AppPreferences(defaults: defaults, fallbackModelID: "img")
        #expect(!reloaded.consistencyCheckEnabled)
        #expect(reloaded.defaultTemplateModelID == "tmpl-x")
        #expect(reloaded.defaultConsistencyModelID == "vis-y")
    }
}
