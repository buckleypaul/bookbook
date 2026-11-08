import BBModel
import CoreGraphics
import Testing
@testable import BBLayout

@MainActor
@Suite("TextBoxLayoutCache")
struct TextBoxLayoutCacheTests {
    init() { LayoutFixtures.registerFonts() }
    let typography = LayoutFixtures.typography
    let size = CGSize(width: 200, height: 100)

    @Test func hitReturnsSameLayout() {
        let cache = TextBoxLayoutCache(capacity: 4)
        let a = cache.layout(text: RichText(plain: "one"), typography: typography, containerSize: size)
        let b = cache.layout(text: RichText(plain: "one"), typography: typography, containerSize: size)
        #expect(a === b)
        #expect(cache.count == 1)
    }

    @Test func keyIncludesTextTypographyAndSize() {
        let cache = TextBoxLayoutCache(capacity: 8)
        let base = cache.layout(text: RichText(plain: "one"), typography: typography, containerSize: size)
        var other = typography
        other.bodySize += 1
        #expect(cache.layout(text: RichText(plain: "two"), typography: typography, containerSize: size) !== base)
        #expect(cache.layout(text: RichText(plain: "one"), typography: other, containerSize: size) !== base)
        #expect(cache.layout(text: RichText(plain: "one"), typography: typography,
                             containerSize: CGSize(width: 201, height: 100)) !== base)
        #expect(cache.count == 4)
    }

    @Test func evictsLeastRecentlyUsed() {
        let cache = TextBoxLayoutCache(capacity: 2)
        let a = cache.layout(text: RichText(plain: "a"), typography: typography, containerSize: size)
        let b = cache.layout(text: RichText(plain: "b"), typography: typography, containerSize: size)
        _ = cache.layout(text: RichText(plain: "a"), typography: typography, containerSize: size) // touch a
        _ = cache.layout(text: RichText(plain: "c"), typography: typography, containerSize: size) // evicts b
        #expect(cache.count == 2)
        #expect(cache.layout(text: RichText(plain: "a"), typography: typography, containerSize: size) === a)
        #expect(cache.layout(text: RichText(plain: "b"), typography: typography, containerSize: size) !== b)
    }

    @Test func removeAllEmpties() {
        let cache = TextBoxLayoutCache(capacity: 2)
        let a = cache.layout(text: RichText(plain: "a"), typography: typography, containerSize: size)
        cache.removeAll()
        #expect(cache.count == 0)
        #expect(cache.layout(text: RichText(plain: "a"), typography: typography, containerSize: size) !== a)
    }

    @Test func rendererUsesCacheWhenSet() {
        let ref = ImageRef(sha256: "aa", contentType: "public.png")
        let content = LayoutFixtures.content(imageRef: ref, imagePixels: PixelSize(width: 4, height: 4))
        var renderer = PageRenderer(images: DictionaryImageSource())
        let cache = TextBoxLayoutCache(capacity: 4)
        renderer.layouts = cache
        _ = renderer.overflowingTextBoxes(page: content.storyPages[0], in: content)
        #expect(cache.count == 1)
    }
}
