# Style preset sample images

Each preset in `../StylePresets.json` may show a sample picture in the Style tab and the new-book
wizard. None are bundled yet; without one, a neutral placeholder is shown.

To add one:

1. In the app, generate a picture in that style at **Standard** quality (not High), roughly square
   or 4:3. Use the same subject for every preset (for example a small fox in a meadow) so they compare.
2. Save the picture and shrink it to at most **768 px on the long side**, JPEG or PNG, **under
   200 KB** each (about 8 presets stay under 2 MB).
3. Name the file after the preset id: `watercolour.jpg`, `crayon.jpg`, `cut-paper.jpg`, and so on.
4. Put it in this folder and add `"sampleImage": "watercolour.jpg"` to that preset in
   `../StylePresets.json`. The key is optional; leave it out for presets without a sample.
