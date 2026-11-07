import Foundation
import SpikeKit
import Testing

extension LiveProviderTests {
    /// SP-6: cancel a high 1024x1536 generation after 5 s (billing is checked by hand on the dashboard next day),
    /// then time one low, one medium and one high 1024² generation (seeds for the catalog's typicalDuration).
    @Test(.timeLimit(.minutes(10)))
    func SP6_cancelAndTiming() async throws {
        let ctx = try LiveContext.make("SP-6")
        let model = SpikeModels.image
        try LiveSpendGuard.requireBudget()

        let client = ctx.client
        let body: [String: any Sendable] = [
            "model": model, "prompt": genPrompt, "size": "1024x1536", "quality": "high", "n": 1, "output_format": "png",
        ]
        let startedAt = isoNow()
        let task = Task<HTTPResponse, any Error> {
            try await client.postJSON("/images/generations", json: body)
        }
        try await Task.sleep(for: .seconds(5))
        let cancelledAt = isoNow()
        task.cancel()
        let outcome = await task.result
        result("SP-6", "cancel.started-utc", startedAt)
        result("SP-6", "cancel.cancelled-utc", cancelledAt + " (check the OpenAI usage dashboard for a charge in this minute)")
        switch outcome {
        case .success(let r):
            result("SP-6", "cancel.outcome", "completed before/despite cancel: status \(r.status), \(milliseconds(r.duration)) ms")
            let usage = Usage.openAI(from: r.body)
            LiveSpendGuard.record(spike: "SP-6", provider: .openai, model: model, usage: usage, estimateUSD: 0.08)
        case .failure(let e):
            result("SP-6", "cancel.error", "\(e)")
            result("SP-6", "cancel.error-is-cancelled", (e as? HTTPClientError).map { if case .cancelled = $0 { true } else { false } } ?? (e is CancellationError))
            // Assume billed until the dashboard says otherwise (plan §4.1).
            LiveSpendGuard.record(spike: "SP-6", provider: .openai, model: model, usage: nil, estimateUSD: 0.08)
        }

        // Timing: one each. The tags print latency-ms.
        for quality in ["low", "medium", "high"] {
            let r = try await ctx.generate(tag: "timing-\(quality)-1024x1024", size: "1024x1024", quality: quality,
                                           fixture: "generations-timing-\(quality)-1024x1024")
            if let r { result("SP-6", "timing.\(quality)-1024x1024-ms", milliseconds(r.duration)) }
        }
    }
}
