import BBModel
import BBStore
import Foundation
import Testing
@testable import BBUI

@MainActor
struct PageNumbersSheetTests {
    @Test func skippedCount_includesFrontMatterAndIgnoresDeletedPages() throws {
        let story = try Presets.storyTemplate()
        let cover = try Presets.coverTemplate()
        let content = BookContent.makeNew(title: "T", storyTemplate: story, coverTemplate: cover,
                                          storyPageCount: 2, now: Date(timeIntervalSince1970: 0))
        var style = PageNumberStyle()
        style.skipFrontMatter = false
        style.skippedPages = [PageID()]  // a deleted page
        #expect(PageNumbersSheet.skippedCount(style: style, content: content, isStoryPage: { _ in false }) == 0)

        let first = try #require(content.storyPages.first)
        style.skippedPages = [first.id, PageID()]
        #expect(PageNumbersSheet.skippedCount(style: style, content: content, isStoryPage: { _ in true }) == 1)

        // Front matter counts when the rule is on.
        var edited = content
        let frontTemplate = try #require(Presets.bundledTemplates.first { $0.pageRole?.isFrontMatter == true })
        edited.templates[frontTemplate.id] = frontTemplate
        edited.pages[first.id]?.templateID = frontTemplate.id
        style.skipFrontMatter = true
        style.skippedPages = []
        #expect(PageNumbersSheet.skippedCount(style: style, content: edited, isStoryPage: { _ in true }) == 1)
    }

    @Test func skippedCount_withoutContent_filtersDeletedIDs() {
        var style = PageNumberStyle()
        let live = PageID()
        style.skippedPages = [live, PageID()]
        #expect(PageNumbersSheet.skippedCount(style: style, content: nil, isStoryPage: { $0 == live }) == 1)
    }

    @Test func sizeParsesWhatItShows_inACommaDecimalLocale() {
        let de = Locale(identifier: "de_DE")
        #expect(PageNumbersSheet.formatSize(10.5, locale: de) == "10,5")
        #expect(PageNumbersSheet.parseSize("10,5", locale: de) == 10.5)
        #expect(PageNumbersSheet.parseSize(PageNumbersSheet.formatSize(12, locale: de), locale: de) == 12)
        let us = Locale(identifier: "en_US")
        #expect(PageNumbersSheet.parseSize("10.5", locale: us) == 10.5)
        #expect(PageNumbersSheet.parseSize("", locale: us) == nil)
        #expect(PageNumbersSheet.parseSize("abc", locale: us) == nil)
    }
}
