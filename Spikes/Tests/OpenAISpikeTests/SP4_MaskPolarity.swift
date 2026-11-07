import Foundation
import SpikeKit
import Testing

private let quadrantColors = [RGB(220, 40, 40), RGB(40, 180, 60), RGB(50, 80, 220), RGB(240, 220, 50)]
private let magenta = RGB(255, 0, 255)

private enum Polarity: String {
    case transparentEdited = "transparent-is-edited"
    case opaqueEdited = "opaque-is-edited"
    case unclear
}

private struct QuadrantStats {
    var mean: RGB
    var distance: Double
    var magentaFraction: Double
}

private func analyse(spike: String, tag: String, image: RGBAImage) -> [Quadrant: QuadrantStats] {
    var out: [Quadrant: QuadrantStats] = [:]
    for (i, q) in Quadrant.allCases.enumerated() {
        let mean = image.meanColor(of: q, inset: 0.1)
        let stats = QuadrantStats(mean: mean, distance: mean.distance(to: quadrantColors[i]),
                                  magentaFraction: image.fraction(of: q, near: magenta, tolerance: 120))
        out[q] = stats
        result(spike, "\(tag).\(q.rawValue)",
               "mean=\(mean.r),\(mean.g),\(mean.b) distance-from-original=\(String(format: "%.1f", stats.distance)) magenta-fraction=\(String(format: "%.3f", stats.magentaFraction))")
    }
    return out
}

private func verdict(_ stats: [Quadrant: QuadrantStats], transparent: Set<Quadrant>) -> Polarity {
    let t = transparent.map { stats[$0]?.magentaFraction ?? 0 }
    let o = Set(Quadrant.allCases).subtracting(transparent).map { stats[$0]?.magentaFraction ?? 0 }
    let tMean = t.reduce(0, +) / Double(max(t.count, 1))
    let oMean = o.reduce(0, +) / Double(max(o.count, 1))
    if tMean > 0.5 && oMean < 0.3 { return .transparentEdited }
    if oMean > 0.5 && tMean < 0.3 { return .opaqueEdited }
    return .unclear
}

/// Counts, along sample lines, how many pixels from the mask boundary away from the edited region still
/// differ noticeably (distance > 60) from the quadrant's original colour. Returns (horizontal, vertical) lists.
private func spill(_ image: RGBAImage, editedIsTopLeft: Bool) -> (horizontal: [Int], vertical: [Int]) {
    let midX = image.width / 2, midY = image.height / 2
    let fractions = [0.1, 0.15, 0.2, 0.25, 0.3, 0.35, 0.4]
    func run(from start: (Int, Int), step: (Int, Int), original: RGB, maxLen: Int) -> Int {
        var x = start.0, y = start.1, last = 0, gap = 0, n = 0
        while n < maxLen, x >= 0, y >= 0, x < image.width, y < image.height {
            if image.pixel(x: x, y: y).distance(to: original) > 60 { last = n + 1; gap = 0 } else { gap += 1 }
            if gap > 3 { break }
            x += step.0; y += step.1; n += 1
        }
        return last
    }
    var h: [Int] = [], v: [Int] = []
    for f in fractions {
        let row = Int(Double(image.height) * f), col = Int(Double(image.width) * f)
        if editedIsTopLeft {
            // Spill into topRight (rightwards) and bottomLeft (downwards).
            h.append(run(from: (midX, row), step: (1, 0), original: quadrantColors[1], maxLen: midX - 1))
            v.append(run(from: (col, midY), step: (0, 1), original: quadrantColors[2], maxLen: midY - 1))
        } else {
            // Edited region is the complement; spill into topLeft (leftwards and upwards).
            h.append(run(from: (midX - 1, row), step: (-1, 0), original: quadrantColors[0], maxLen: midX - 1))
            v.append(run(from: (col, midY - 1), step: (0, -1), original: quadrantColors[0], maxLen: midY - 1))
        }
    }
    return (h, v)
}

private func median(_ xs: [Int]) -> Int { xs.sorted()[xs.count / 2] }

extension LiveProviderTests {
    /// SP-4: is the edit area the transparent or the opaque part of the mask? Plus spill and size-mismatch error.
    @Test(.timeLimit(.minutes(10)))
    func SP4_maskPolarity() async throws {
        let ctx = try LiveContext.make("SP-4")
        let model = SpikeModels.image
        let base = TestImages.quadrants(size: 1024, colors: quadrantColors)
        let prompt = "Fill the editable area with bright magenta; leave everything else unchanged."

        let maskA = TestImages.mask(size: 1024, transparent: [.topLeft])
        let maskBSet: Set<Quadrant> = [.topRight, .bottomLeft, .bottomRight]
        let maskB = TestImages.mask(size: 1024, transparent: maskBSet)

        func form(_ mask: Data) -> MultipartForm {
            editForm(prompt: prompt, size: "1024x1024", images: [("base.png", base)], mask: mask)
        }

        var verdicts: [Polarity] = []
        var editedIsTopLeft: Bool?

        let a = try await ctx.perform(.multipart("/images/edits", form(maskA)), tag: "maskA-topLeft-transparent",
                                      model: model, estimateUSD: 0.03, fixture: "edits-maskA-topLeft-transparent")
        #expect(a?.status == 200)
        if let a, let img = firstImage(a) {
            let stats = analyse(spike: "SP-4", tag: "maskA", image: img)
            let v = verdict(stats, transparent: [.topLeft])
            result("SP-4", "maskA.verdict", v.rawValue)
            verdicts.append(v)
            if v != .unclear { editedIsTopLeft = (v == .transparentEdited) }
            // Spill: assume the region implied by this verdict (default: transparent is edited).
            let tl = editedIsTopLeft ?? true
            let s = spill(img, editedIsTopLeft: tl)
            result("SP-4", "maskA.spill-px.horizontal", "median=\(median(s.horizontal)) max=\(s.horizontal.max() ?? 0) samples=\(s.horizontal) (result px; edited-is-topLeft=\(tl))")
            result("SP-4", "maskA.spill-px.vertical", "median=\(median(s.vertical)) max=\(s.vertical.max() ?? 0) samples=\(s.vertical)")
            result("SP-4", "maskA.spill-px.estimate", max(median(s.horizontal), median(s.vertical)))
        }

        let b = try await ctx.perform(.multipart("/images/edits", form(maskB)), tag: "maskB-inverse",
                                      model: model, estimateUSD: 0.03, fixture: "edits-maskB-inverse")
        if let b, let img = firstImage(b) {
            let stats = analyse(spike: "SP-4", tag: "maskB", image: img)
            let v = verdict(stats, transparent: maskBSet)
            result("SP-4", "maskB.verdict", v.rawValue)
            verdicts.append(v)
        }

        let clear = Set(verdicts.filter { $0 != .unclear })
        let final: Polarity = clear.count == 1 ? clear.first! : .unclear
        result("SP-4", "polarity", final.rawValue)

        // Mask whose size doesn't match the base.
        let small = TestImages.mask(size: 512, transparent: [.topLeft])
        try await ctx.perform(.multipart("/images/edits", form(small)), tag: "mask-size-mismatch-512",
                              model: model, estimateUSD: 0.03, fixture: "edits-mask-size-mismatch")
    }
}

extension LiveProviderTests {
    /// SP-4 follow-up: mask B (three transparent quadrants) changed every quadrant, so polarity is confirmed with
    /// a second single-quadrant mask. "Changed" uses colour distance (> 60) as well as the magenta fraction.
    @Test(.timeLimit(.minutes(5)))
    func SP4b_maskPolaritySecondQuadrant() async throws {
        let ctx = try LiveContext.make("SP-4")
        let base = TestImages.quadrants(size: 1024, colors: quadrantColors)
        let prompt = "Fill the editable area with bright magenta; leave everything else unchanged."
        let maskC = TestImages.mask(size: 1024, transparent: [.bottomRight])
        let form = editForm(prompt: prompt, size: "1024x1024", images: [("base.png", base)], mask: maskC)
        let c = try await ctx.perform(.multipart("/images/edits", form), tag: "maskC-bottomRight-transparent",
                                      model: SpikeModels.image, estimateUSD: 0.015,
                                      fixture: "edits-maskC-bottomRight-transparent", keepRealImage: true)
        #expect(c?.status == 200)
        guard let c, let img = firstImage(c) else { return }
        let stats = analyse(spike: "SP-4", tag: "maskC", image: img)
        let changed = Quadrant.allCases.filter { (stats[$0]?.distance ?? 0) > 60 }.map(\.rawValue)
        for q in Quadrant.allCases {
            let (x0, y0) = (q == .topLeft || q == .bottomLeft ? 0 : img.width / 2, q == .topLeft || q == .topRight ? 0 : img.height / 2)
            var sum = 0, n = 0
            for y in stride(from: y0 + 50, to: y0 + img.height / 2 - 50, by: 16) {
                for x in stride(from: x0 + 50, to: x0 + img.width / 2 - 50, by: 16) { sum += Int(img.alpha(x: x, y: y)); n += 1 }
            }
            result("SP-4", "maskC.alpha.\(q.rawValue)", sum / max(n, 1))
        }
        result("SP-4", "maskC.changed-quadrants", changed.joined(separator: ","))
        result("SP-4", "maskC.verdict", verdict(stats, transparent: [.bottomRight]).rawValue)
    }
}

extension LiveProviderTests {
    /// SP-4 follow-up: does the model still see the original pixels under the transparent mask area?
    /// Asks it to keep the area's colour and add a small white star. Yellow comes back → it sees the pixels.
    @Test(.timeLimit(.minutes(5)))
    func SP4c_maskAreaContentVisible() async throws {
        let ctx = try LiveContext.make("SP-4")
        let base = TestImages.quadrants(size: 1024, colors: quadrantColors)
        let prompt = "Inside the editable area, draw one small white star in its centre. Keep the area's existing background colour exactly as it is."
        let maskC = TestImages.mask(size: 1024, transparent: [.bottomRight])
        let form = editForm(prompt: prompt, size: "1024x1024", images: [("base.png", base)], mask: maskC)
        let c = try await ctx.perform(.multipart("/images/edits", form), tag: "maskC-keep-colour-add-star",
                                      model: SpikeModels.image, estimateUSD: 0.015,
                                      fixture: "edits-maskC-keep-colour-add-star")
        guard let c, let img = firstImage(c) else { return }
        _ = analyse(spike: "SP-4", tag: "maskC-star", image: img)
    }
}
