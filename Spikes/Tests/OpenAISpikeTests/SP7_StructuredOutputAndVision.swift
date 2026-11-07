import Foundation
import SpikeKit
import Testing

// TemplateDraft (architecture.md §7.7): every property required, additionalProperties false, nullable via
// type arrays, enums for kinds/alignments, coordinates are numbers meant to be 0…1 (validated locally).
private let templateDraftSchema = """
{
  "type": "object",
  "additionalProperties": false,
  "required": ["name", "boxes"],
  "properties": {
    "name": {"type": "string"},
    "boxes": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["kind", "x", "y", "width", "height", "textAlignment", "cornerRadius"],
        "properties": {
          "kind": {"type": "string", "enum": ["image", "text"]},
          "x": {"type": "number"},
          "y": {"type": "number"},
          "width": {"type": "number"},
          "height": {"type": "number"},
          "textAlignment": {"type": ["string", "null"], "enum": ["leading", "center", "trailing", "justified", null]},
          "cornerRadius": {"type": ["number", "null"]}
        }
      }
    }
  }
}
"""

// Consistency output (architecture.md §7.8).
private let consistencySchema = """
{
  "type": "object",
  "additionalProperties": false,
  "required": ["consistent", "differences"],
  "properties": {
    "consistent": {"type": "boolean"},
    "differences": {
      "type": "array",
      "items": {
        "type": "object",
        "additionalProperties": false,
        "required": ["asset", "aspect", "observed", "expected", "severity"],
        "properties": {
          "asset": {"type": ["string", "null"]},
          "aspect": {"type": "string"},
          "observed": {"type": "string"},
          "expected": {"type": "string"},
          "severity": {"type": "string", "enum": ["minor", "major"]}
        }
      }
    }
  }
}
"""

private func responseFormat(name: String, schema: [String: any Sendable]) -> [String: any Sendable] {
    let js: [String: any Sendable] = ["name": name, "strict": true, "schema": schema]
    return ["type": "json_schema", "json_schema": js]
}

private struct ChatOutcome {
    var content: String?
    var refusal: String?
    var finishReason: String?
}

private func parseChat(_ response: HTTPResponse) -> ChatOutcome {
    let choice = (response.json?["choices"] as? [[String: Any]])?.first
    let message = choice?["message"] as? [String: Any]
    func nonNull(_ v: Any?) -> String? { (v is NSNull) ? nil : v as? String }
    return ChatOutcome(content: nonNull(message?["content"]), refusal: nonNull(message?["refusal"]),
                       finishReason: nonNull(choice?["finish_reason"]))
}

private func number(_ v: Any?) -> Double? { (v as? NSNumber).flatMap { $0 === kCFBooleanTrue || $0 === kCFBooleanFalse ? nil : $0.doubleValue } }

/// Returns a list of problems; empty means valid.
private func validateTemplateDraft(_ text: String) -> [String] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return ["not a JSON object"] }
    var problems: [String] = []
    if !(obj["name"] is String) { problems.append("name missing or not a string") }
    guard let boxes = obj["boxes"] as? [[String: Any]] else { return problems + ["boxes missing or not an array"] }
    if boxes.isEmpty { problems.append("no boxes") }
    for (i, box) in boxes.enumerated() {
        let kind = box["kind"] as? String
        if kind != "image" && kind != "text" { problems.append("box \(i): bad kind \(String(describing: kind))") }
        for k in ["x", "y", "width", "height"] {
            guard let n = number(box[k]) else { problems.append("box \(i): \(k) missing/not a number"); continue }
            if n < 0 || n > 1 { problems.append("box \(i): \(k)=\(n) outside 0…1") }
        }
        if let x = number(box["x"]), let w = number(box["width"]), x + w > 1.001 { problems.append("box \(i): x+width > 1") }
        if let y = number(box["y"]), let h = number(box["height"]), y + h > 1.001 { problems.append("box \(i): y+height > 1") }
        guard box.keys.contains("textAlignment"), box.keys.contains("cornerRadius") else {
            problems.append("box \(i): nullable keys not all present"); continue
        }
        if let a = box["textAlignment"], !(a is NSNull) {
            if !["leading", "center", "trailing", "justified"].contains(a as? String ?? "") { problems.append("box \(i): bad textAlignment") }
        }
        if let c = box["cornerRadius"], !(c is NSNull), number(c) == nil { problems.append("box \(i): cornerRadius not a number/null") }
    }
    return problems
}

private func validateConsistency(_ text: String) -> [String] {
    guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return ["not a JSON object"] }
    var problems: [String] = []
    if !(obj["consistent"] is Bool) { problems.append("consistent missing or not a bool") }
    guard let diffs = obj["differences"] as? [[String: Any]] else { return problems + ["differences missing or not an array"] }
    for (i, d) in diffs.enumerated() {
        if !d.keys.contains("asset") || !((d["asset"] is String) || (d["asset"] is NSNull)) { problems.append("diff \(i): asset must be string|null") }
        for k in ["aspect", "observed", "expected"] where !(d[k] is String) { problems.append("diff \(i): \(k) missing") }
        if !["minor", "major"].contains(d["severity"] as? String ?? "") { problems.append("diff \(i): bad severity") }
    }
    return problems
}

extension LiveProviderTests {
    /// SP-7: Chat Completions structured output (TemplateDraft) and vision (consistency) with `store: false`.
    @Test(.timeLimit(.minutes(10)))
    func SP7_structuredOutputAndVision() async throws {
        let ctx = try LiveContext.make("SP-7")

        // Part 1: template generation.
        let templateModel = SpikeModels.template
        let userText = """
        Page setup: 8.5 x 8.5 inch square page, portrait orientation, 0.5 inch margins, 0.125 inch bleed, single page.
        Design a picture-book page template: a big picture on the top two thirds of the page and the text below it. \
        Use normalised coordinates between 0 and 1 relative to the page. Give the template a short name.
        """
        let templateMessages: [any Sendable] = [
            ["role": "system", "content": "You design page layouts for children's picture books. Reply only with the requested JSON."] as [String: any Sendable],
            ["role": "user", "content": userText] as [String: any Sendable],
        ]
        let templateBody: [String: any Sendable] = [
            "model": templateModel,
            "store": false,
            "messages": templateMessages,
            "response_format": responseFormat(name: "TemplateDraft", schema: try jsonObject(templateDraftSchema)),
        ]
        let t = try await ctx.perform(.json("/chat/completions", templateBody), tag: "template", model: templateModel,
                                      estimateUSD: 0.01, fixture: "chat-template-draft")
        if let t {
            if (200..<300).contains(t.status) {
                let out = parseChat(t)
                result("SP-7", "template.finish-reason", out.finishReason ?? "nil")
                result("SP-7", "template.refusal", out.refusal ?? "none")
                if let content = out.content {
                    result("SP-7", "template.content", String(content.prefix(900)))
                    let problems = validateTemplateDraft(content)
                    result("SP-7", "template.valid", problems.isEmpty)
                    if !problems.isEmpty { result("SP-7", "template.problems", problems.joined(separator: "; ")) }
                    #expect(problems.isEmpty, "TemplateDraft validation: \(problems)")
                } else if out.refusal == nil {
                    Issue.record("template response had neither content nor refusal")
                }
            } else {
                result("SP-7", "chat-completions-unsupported",
                       "template request failed with status \(t.status) on model \(templateModel); see template.error.* lines")
            }
        }

        // Part 2: vision consistency check, two small images as data URLs at low detail.
        let visionModel = SpikeModels.vision
        let reference = TestImages.solid(width: 256, height: 256, color: RGB(220, 30, 30))
        let candidate = TestImages.solid(width: 256, height: 256, color: RGB(30, 60, 220))
        func imagePart(_ data: Data) -> [String: any Sendable] {
            let url: [String: any Sendable] = ["url": "data:image/png;base64," + data.base64EncodedString(), "detail": "low"]
            return ["type": "image_url", "image_url": url]
        }
        let visionPrompt = """
        Image 1 is the reference for the asset "Pip's scarf" (expected: solid red). Image 2 is a newly generated candidate that \
        should show the same scarf colour. Compare them and report any differences in the required JSON format. \
        Use severity "major" for a clearly different colour.
        """
        let textPart: [String: any Sendable] = ["type": "text", "text": visionPrompt]
        let content: [any Sendable] = [textPart, imagePart(reference), imagePart(candidate)]
        let visionMessages: [any Sendable] = [["role": "user", "content": content] as [String: any Sendable]]
        let visionBody: [String: any Sendable] = [
            "model": visionModel,
            "store": false,
            "messages": visionMessages,
            "response_format": responseFormat(name: "ConsistencyReport", schema: try jsonObject(consistencySchema)),
        ]
        let v = try await ctx.perform(.json("/chat/completions", visionBody), tag: "vision", model: visionModel,
                                      estimateUSD: 0.01, fixture: "chat-consistency")
        if let v {
            if (200..<300).contains(v.status) {
                let out = parseChat(v)
                result("SP-7", "vision.finish-reason", out.finishReason ?? "nil")
                result("SP-7", "vision.refusal", out.refusal ?? "none")
                if let content = out.content {
                    result("SP-7", "vision.content", String(content.prefix(900)))
                    let problems = validateConsistency(content)
                    result("SP-7", "vision.valid", problems.isEmpty)
                    if !problems.isEmpty { result("SP-7", "vision.problems", problems.joined(separator: "; ")) }
                    if let obj = (try? JSONSerialization.jsonObject(with: Data(content.utf8))) as? [String: Any] {
                        result("SP-7", "vision.reports-inconsistency", (obj["consistent"] as? Bool) == false)
                    }
                    #expect(problems.isEmpty, "Consistency validation: \(problems)")
                } else if out.refusal == nil {
                    Issue.record("vision response had neither content nor refusal")
                }
            } else {
                result("SP-7", "chat-completions-unsupported",
                       "vision request failed with status \(v.status) on model \(visionModel); see vision.error.* lines")
            }
        }
    }
}
