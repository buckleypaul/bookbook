# BBStoreTests fixtures

Copied into the test bundle (`Bundle.module`). `SchemaV1.bookbook/` is a schema v1 package used by the migration tests (Phase 3).

Generated once with `BookStore.create(BookContent.makeNew(title: "Fixture Book", author: "Test Author", storyPageCount: 1, now: 2027-01-15T08:00:00Z))` using the bundled presets: book.json, style.json, 2 templates (story, cover), a story page, the cover page and one session per image box. The empty `images/` folder is not committed. Do not regenerate it; a later schema bump gets its own `SchemaV<N>.bookbook`.
