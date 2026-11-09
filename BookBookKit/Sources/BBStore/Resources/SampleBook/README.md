# Sample book

`Sample.bookbook` is the book "Open Sample Book" copies into the library (with a new book ID).

Right now it is a text-only placeholder (6 story pages, a main character, the Watercolour preset)
made by `Tests/BBStoreTests/SampleBookGenerator.swift`:

    BOOKBOOK_GENERATE_SAMPLE=1 swift test --filter SampleBookGenerator

To replace it with the real sample (6 to 8 pages with pictures, under 15 MB):

1. In the app, make the book at Standard quality and clean it up (Book Settings > Clean up).
2. Quit the app so the package has no `.lock` or `.journal`, then copy the package from the
   library folder over `Sample.bookbook` (keep that exact name).
3. Check `du -sh Sample.bookbook` is under 15 MB, and that the tests in `NewBookSpecTests` pass.
