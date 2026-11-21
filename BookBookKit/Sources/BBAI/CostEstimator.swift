import BBAICore
import BBModel
import Foundation

/// Pure cost estimates for image requests (A §7.10).
public enum CostEstimator {
    /// Uploaded images whose pixel size isn't known are assumed to be this size.
    static let assumedImageSize = PixelSize(width: 1024, height: 1024)

    public static func estimate(_ input: ImageEstimateInput, priceList: PriceList) -> CostEstimate {
        guard let entry = priceList.entry(provider: input.model.provider, model: input.model.pricingModelID)
        else { return .unknown }
        let table = entry.estimation

        // Output image tokens.
        guard let param = input.model.image.quality[input.quality]?.param,
              let outputTable = table?.outputImageTokens,
              let output = outputTokens(param: param, size: input.outputSize, table: outputTable)
        else { return .unknown }
        var extrapolated = output.extrapolated

        // Input image tokens.
        var imageIn = 0
        for size in input.inputImageSizes {
            if let exact = table?.inputImageTokens?["\(size.width)x\(size.height)"] {
                imageIn += exact
            } else {
                imageIn += patchTokens(size)
                extrapolated = true
            }
        }

        let textIn = entry.textTokens(characters: input.promptCharacters)
        let amount = PriceEntry.cost((entry.rate(.textIn), Decimal(textIn)),
                                     (entry.rate(.imageIn), Decimal(imageIn)),
                                     (entry.rate(.imageOut), Decimal(output.tokens)))
        return CostEstimate(amount: amount, extrapolated: extrapolated, priceListAsOf: entry.asOf)
    }

    /// "Downscale so the longer side is at most 512 px, then one token per 16x16 patch" (A §7.10).
    static func patchTokens(_ size: PixelSize) -> Int {
        var w = Double(max(1, size.width)), h = Double(max(1, size.height))
        let longer = max(w, h)
        if longer > 512 {
            let scale = 512 / longer
            w *= scale
            h *= scale
        }
        return Int((w / 16).rounded(.up)) * Int((h / 16).rounded(.up))
    }

    private static func outputTokens(param: String, size: PixelSize, table: [String: Int]) -> (tokens: Int, extrapolated: Bool)? {
        if let exact = table["\(param)@\(size.width)x\(size.height)"] { return (exact, false) }
        let target = size.width * size.height
        var best: (distance: Int, tokens: Int)?
        for (key, tokens) in table {
            let parts = key.split(separator: "@", maxSplits: 1)
            guard parts.count == 2, parts[0] == param else { continue }
            let dims = parts[1].split(separator: "x")
            guard dims.count == 2, let w = Int(dims[0]), let h = Int(dims[1]) else { continue }
            let distance = abs(w * h - target)
            if let current = best {
                if distance < current.distance || (distance == current.distance && tokens > current.tokens) {
                    best = (distance, tokens)
                }
            } else {
                best = (distance, tokens)
            }
        }
        return best.map { ($0.tokens, true) }
    }

    /// Builds the estimator input for one queue item without loading image bytes. Runs the
    /// assembler's own planning and limits with placeholder bytes, so the prompt and the images
    /// counted match what would be sent. Pixel sizes the book doesn't know (style references)
    /// are assumed to be 1024x1024. Nil if the model or target can't be resolved.
    public static func estimateInput(intent: GenerationIntent, target: GenerationTarget, content: BookContent,
                                     catalog: ModelCatalog) -> ImageEstimateInput? {
        guard let model = catalog.imageModel(provider: intent.provider, id: intent.model),
              let prepared = ContextAssembler.prepare(intent: intent, target: target, messageID: nil, content: content)
        else { return nil }
        let planned = ContextAssembler.plan(prepared)
        var data: [ImageRef: Data] = [:]
        for image in planned { data[image.ref] = Data([0]) }
        // A region edit's mask (A §7.6) isn't encoded: only the prompt and the images sent are counted.
        guard let (request, report) = try? ContextAssembler.assemble(
            prepared: prepared, intent: intent, content: content, model: model, imageData: data, encodingMask: false)
        else { return nil }
        // A mask needs a base image to edit: no estimate without one, as the assembler refuses it.
        guard intent.regionMask == nil || request.baseImage != nil else { return nil }

        var knownSizes: [ImageRef: PixelSize] = [:]
        for image in planned { if let size = image.pixelSize { knownSizes[image.ref] = size } }
        let sizes = report.referencesSent.map { knownSizes[$0.image] ?? assumedImageSize }

        let outputSize: PixelSize
        if let exact = request.output.exactSize {
            outputSize = exact
        } else {
            switch AspectFitter.fit(boxAspect: request.output.boxAspect, model: model, quality: intent.quality) {
            case let .pixels(size):
                outputSize = size
            case let .ratio(ratio):
                let aspect = AspectFitter.ratioValue(ratio)
                let height = (Double(AspectFitter.defaultTargetPixels) / aspect).squareRoot()
                outputSize = PixelSize(width: Int((height * aspect).rounded()), height: Int(height.rounded()))
            }
        }
        return ImageEstimateInput(model: model, quality: intent.quality, outputSize: outputSize,
                                  inputImageSizes: sizes, promptCharacters: report.promptText.count)
    }
}
