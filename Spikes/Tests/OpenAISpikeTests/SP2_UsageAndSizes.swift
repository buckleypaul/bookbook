import Foundation
import SpikeKit
import Testing

extension LiveProviderTests {
    /// SP-2: usage/cost fields, latency, accepted sizes (free sizes, below minPixels, above 2560x1440).
    /// Expected output-image tokens come from architecture.md §7.10 (low 200, medium 433, high 1767 at 1024²).
    @Test(.timeLimit(.minutes(10)))
    func SP2_usageAndSizes() async throws {
        let ctx = try LiveContext.make("SP-2")
        let base = try await ctx.generate(tag: "low-1024x1024", size: "1024x1024", quality: "low",
                                          fixture: "generations-low-1024x1024", keepRealImage: true)
        #expect(base?.status == 200)
        try await ctx.generate(tag: "low-1024x1536", size: "1024x1536", quality: "low", fixture: "generations-low-1024x1536")
        try await ctx.generate(tag: "low-free-1232x816", size: "1232x816", quality: "low", fixture: "generations-low-free-1232x816")
        try await ctx.generate(tag: "medium-1024x1024", size: "1024x1024", quality: "medium", fixture: "generations-medium-1024x1024")
        try await ctx.generate(tag: "high-1024x1024", size: "1024x1024", quality: "high", fixture: "generations-high-1024x1024")
        // Below minPixels and above the 2560x1440 "experimental" line: record, don't assert.
        try await ctx.generate(tag: "below-min-512x512", size: "512x512", quality: "low", fixture: "generations-below-min-512x512")
        try await ctx.generate(tag: "above-max-3840x2160", size: "3840x2160", quality: "low",
                               fixture: "generations-above-max-3840x2160", estimate: 0.05)
    }
}
