import Foundation
import SpikeKit
import Testing

extension LiveProviderTests {
    /// SP-5: refusal shape (at most 2 blockable requests) and free error cases.
    @Test(.timeLimit(.minutes(10)))
    func SP5_refusalsAndErrors() async throws {
        let ctx = try LiveContext.make("SP-5")

        // 1. Policy blocks: graphic violence only, no real people, no minors. Capped at 2 requests.
        let blockable = [
            "A photorealistic, extremely graphic scene of a gruesome massacre: dismembered bodies and pools of blood.",
            "A hyper-realistic close-up of a brutal torture scene with exposed viscera and graphic gore.",
        ]
        for (i, prompt) in blockable.enumerated() {
            let r = try await ctx.generate(tag: "blocked-\(i + 1)", size: "1024x1024", quality: "low", prompt: prompt,
                                           fixture: "generations-blocked-\(i + 1)", estimate: 0)
            if let r {
                let e = errorInfo(r)
                result("SP-5", "blocked-\(i + 1).summary",
                       "status=\(r.status) type=\(e.type ?? "nil") code=\(e.code ?? "nil") (status 200 means not blocked)")
                if let details = (r.json?["error"] as? [String: Any])?["moderation_details"] {
                    result("SP-5", "blocked-\(i + 1).moderation_details", compactJSON(details))
                }
                if r.status == 200 { break }  // not blocked; don't push the account further
            }
        }

        // 2. Bogus key (401 expected). The recorder still checks fixtures against the real key.
        if let realKey = LiveEnvironment.apiKey(.openai) {
            let bad = LiveContext(client: OpenAIClient(key: .invalidForTesting()),
                                  recorder: FixtureRecorder(provider: .openai, spike: "SP-5", key: realKey),
                                  spike: "SP-5")
            try await bad.perform(.get("/models"), tag: "invalid-key", model: "none", estimateUSD: 0,
                                  fixture: "models-invalid-key")
        }

        // 3. Unknown model (404 expected).
        try await ctx.generate(tag: "unknown-model", size: "1024x1024", quality: "low",
                               model: "gpt-image-does-not-exist", fixture: "generations-unknown-model", estimate: 0)
        // 4. Invalid sizes (400 expected).
        try await ctx.generate(tag: "invalid-size-1000x1000", size: "1000x1000", quality: "low",
                               fixture: "generations-invalid-size-1000", estimate: 0)
        try await ctx.generate(tag: "invalid-size-1023x1023", size: "1023x1023", quality: "low",
                               fixture: "generations-invalid-size-1023", estimate: 0)

        // 5. Oversized upload to /images/edits. Default 4400x4400 RGB noise (about 58 MB, above the ~50 MB per-image
        //    limit); override with SPIKE_OVERSIZE_PX (e.g. 3600 for about 39 MB). Generated once, in memory.
        let px = Int(LiveEnvironment.string("SPIKE_OVERSIZE_PX", default: "4400")) ?? 4400
        let big = TestImages.noise(width: px, height: px, seed: 42)
        result("SP-5", "oversized.upload-bytes", big.count)
        try await ctx.perform(
            .multipart("/images/edits", editForm(prompt: "Keep the image as it is.", size: "1024x1024",
                                                 images: [("big.png", big)])),
            tag: "oversized-upload", model: SpikeModels.image, estimateUSD: 0, fixture: "edits-oversized-upload")
    }
}
