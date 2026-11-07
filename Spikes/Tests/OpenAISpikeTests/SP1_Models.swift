import Foundation
import SpikeKit
import Testing

extension LiveProviderTests {
    /// SP-1: which catalog models does the key see, and is the organisation verified for GPT Image?
    @Test(.timeLimit(.minutes(10)))
    func SP1_models() async throws {
        let ctx = try LiveContext.make("SP-1")
        let seeds = ["gpt-image-2.5-sunburst", "gpt-image-2.6-sunburst", "gpt-image-2.6-flare", "gpt-image-2",
                     "gpt-6-luna", "gpt-6.1-terra"]
        if let r = try await ctx.perform(.get("/models"), tag: "models", model: "n/a", estimateUSD: 0, fixture: "models") {
            #expect(r.status == 200)
            let ids = ((r.json?["data"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }.sorted()
            result("SP-1", "models.count", ids.count)
            for seed in seeds { result("SP-1", "seed.\(seed)", ids.contains(seed) ? "present" : "absent") }
            let interesting = ids.filter { $0.contains("image") || $0.hasPrefix("gpt-6") }
            result("SP-1", "models.image-or-gpt-6", interesting.joined(separator: ","))
        }
        // One tiny low generation: does a 403 organisation-verification error come back?
        let gen = try await ctx.generate(tag: "verify-generation-low-1024x1024", size: "1024x1024", quality: "low",
                                         prompt: "A small red circle on a white background.",
                                         fixture: "generations-low-1024x1024", estimate: 0.006)
        if let gen {
            result("SP-1", "verification", gen.status == 403 ? "403: verification/permission error (see body above)"
                   : (gen.status == 200 ? "ok (generation succeeded)" : "status \(gen.status) (see body above)"))
        }
    }
}
