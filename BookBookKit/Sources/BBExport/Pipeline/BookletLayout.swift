import CoreGraphics

/// Two-up slot geometry for booklet sheets (A §9.3, PD §8.8).
///
/// Portrait (or square) pages sit side by side on a landscape sheet (fold vertical); landscape
/// pages stack on a portrait sheet (fold horizontal). Both print with a short-edge flip: the
/// fold runs parallel to the short edge, and turning the sheet over about the fold axis puts
/// the back's first slot behind the front's second slot (page 2 behind page 1, n − 1 behind n)
/// with the back upright as the folded booklet opens. A long-edge flip on the stacked layout
/// would put page n behind page 2 and the back upside down. Each page is scaled by
/// `min(1, fit)` and centred in its half. A scale within `tolerance` of 1 counts as 1, so 5.5×8.5 in on Letter and A5 on A4
/// (sizes rounded to 0.01 pt) print at 100 %.
extension BookletImposition {
    static let tolerance: CGFloat = 0.002
    static let shortEdgeInstructions = "Print double-sided, flip on short edge."

    /// Slot geometry for one trim-size page (single page, not spread) on a sheet.
    public static func layout(pageSize: CGSize, sheet: SheetSize) -> BookletSheetLayout {
        let portrait = sheet.portraitSize
        let sideBySide = pageSize.width <= pageSize.height
        let sheetSize: CGSize
        let first: CGRect
        let second: CGRect
        if sideBySide {
            sheetSize = CGSize(width: portrait.height, height: portrait.width)
            let half = sheetSize.width / 2
            first = CGRect(x: 0, y: 0, width: half, height: sheetSize.height)
            second = CGRect(x: half, y: 0, width: half, height: sheetSize.height)
        } else {
            sheetSize = portrait
            let half = sheetSize.height / 2
            first = CGRect(x: 0, y: 0, width: sheetSize.width, height: half)
            second = CGRect(x: 0, y: half, width: sheetSize.width, height: half)
        }
        var scale: CGFloat = 1
        if pageSize.width > 0, pageSize.height > 0 {
            scale = min(1, first.width / pageSize.width, first.height / pageSize.height)
        }
        if scale > 1 - tolerance { scale = 1 }
        return BookletSheetLayout(sheetSize: sheetSize, firstSlot: first, secondSlot: second, scale: scale,
                                  printingInstructions: shortEdgeInstructions)
    }

    /// Where a page of `pageSize` goes in `slot` at `scale`: centred.
    static func pageRect(in slot: CGRect, pageSize: CGSize, scale: CGFloat) -> CGRect {
        let size = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
        return CGRect(x: slot.midX - size.width / 2, y: slot.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
}
