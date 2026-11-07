import Foundation
import SpikeKit
import Testing

extension LiveProviderTests {
    /// SP-3: /images/edits with a base plus references; image-count cap (16 vs 17).
    @Test(.timeLimit(.minutes(10)))
    func SP3_editsWithReferences() async throws {
        let ctx = try LiveContext.make("SP-3")
        let model = SpikeModels.image
        let colors = [RGB(220, 40, 40), RGB(40, 180, 60), RGB(50, 80, 220), RGB(240, 220, 50)]
        let base = TestImages.quadrants(size: 1024, colors: colors)

        // Base + 3 references (distinct solid colours).
        let refColors = [RGB(255, 0, 255), RGB(0, 255, 255), RGB(255, 128, 0)]
        var images: [(name: String, data: Data)] = [("base.png", base)]
        for (i, c) in refColors.enumerated() {
            images.append(("ref\(i + 1).png", TestImages.solid(width: 256, height: 256, color: c)))
        }
        let prompt = "Image 1 is the base: keep its four-quadrant layout and size. Images 2, 3 and 4 are colour references; "
            + "paint a small circle in the centre of image 1 using the colour of image 2."
        let main = try await ctx.perform(
            .multipart("/images/edits", editForm(prompt: prompt, size: "auto", images: images)),
            tag: "base-plus-3-refs-auto", model: model, estimateUSD: 0.02,
            fixture: "edits-base-plus-3-refs", keepRealImage: true)
        #expect(main?.status == 200)
        if let main, let img = firstImage(main) {
            result("SP-3", "base-plus-3-refs-auto.output-keeps-base-size", img.width == 1024 && img.height == 1024)
            let centre = img.pixel(x: img.width / 2, y: img.height / 2)
            result("SP-3", "base-plus-3-refs-auto.centre-pixel", "\(centre.r),\(centre.g),\(centre.b) (image 2 colour was 255,0,255)")
            for q in Quadrant.allCases {
                let m = img.meanColor(of: q, inset: 0.3)
                result("SP-3", "base-plus-3-refs-auto.mean.\(q.rawValue)", "\(m.r),\(m.g),\(m.b)")
            }
        }
        // Same with the explicit base size, to compare size handling and input-token counts.
        try await ctx.perform(
            .multipart("/images/edits", editForm(prompt: prompt, size: "1024x1024", images: images)),
            tag: "base-plus-3-refs-1024", model: model, estimateUSD: 0.02, fixture: "edits-base-plus-3-refs-1024")

        // 16 and 17 images (tiny, to keep cost and upload small).
        func many(_ n: Int) -> [(name: String, data: Data)] {
            (0..<n).map { i in
                let v = UInt8((i * 15) % 256)
                let color = RGB(v, UInt8(255 - Int(v)), UInt8((i * 40) % 256))
                return ("img\(i + 1).png", TestImages.solid(width: 128, height: 128, color: color))
            }
        }
        let p = "Image 1 is the base. Keep it as it is."
        try await ctx.perform(.multipart("/images/edits", editForm(prompt: p, size: "1024x1024", images: many(16))),
                              tag: "16-images", model: model, estimateUSD: 0.05, fixture: "edits-16-images")
        try await ctx.perform(.multipart("/images/edits", editForm(prompt: p, size: "1024x1024", images: many(17))),
                              tag: "17-images", model: model, estimateUSD: 0.05, fixture: "edits-17-images")
    }
}
