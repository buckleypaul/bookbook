# BookBook

BookBook is a native macOS app for making illustrated children's books with AI image generation. You write the story. BookBook helps you illustrate it consistently by building a library of reusable assets (characters, places, objects), a book-wide style guide, and page templates. Then you make each picture in its own AI session. Finished books export to PDF for home printing (as single pages or a fold-and-staple booklet) or for a local print shop.

## Requirements

- macOS 27.0 or later
- Xcode 27.x (Swift 6.4, strict concurrency)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) 2.46.0: `brew install xcodegen`

## First-time setup

After cloning, install the secret-scanning hook once:

```sh
scripts/install-hooks.sh
```

The hook runs `scripts/secret-scan.sh --staged` before every commit and merge, and fails closed if the scanner is missing.

## Open and run

```sh
xcodegen generate        # only after editing project.yml
open BookBook.xcodeproj
```

Select the **BookBook** scheme and run. `BookBook.xcodeproj` is generated from `project.yml`, which is the source of truth. Don't hand-edit the project. To change it, edit `project.yml`, run `xcodegen generate`, and commit both files.

## Tests

`scripts/test.sh` runs the same steps as CI. Pass a step name, or `all` (the default):

| Step | What it runs |
|---|---|
| `all` | every step below |
| `secrets` | the secret scan over all tracked files |
| `bootstrap` | the offline self-test for the hook and key scripts |
| `kit` | `swift test` in `BookBookKit` |
| `spikes` | `swift test` in `Spikes` |
| `xcodeproj` | checks that the generated project matches `project.yml` |
| `app` | `xcodebuild build test` for the app |
| `release` | an unsigned Release build |

To run only the package tests:

```sh
cd BookBookKit && swift test
```

Live provider tests are opt-in and never run in CI. They call real APIs and spend money, so run them only through `scripts/live-tests.sh` or `scripts/record-fixtures.sh`. They are capped at $10 in total. The key-handling rules are in [CLAUDE.md](CLAUDE.md) (API key hygiene). Don't read or print API keys in your own commands.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | the thin app target: `@main`, scenes, Info.plist, entitlements; app tests in `App/BookBookTests` |
| `BookBookKit/` | local Swift package with every module (BBModel, BBStore, BBLayout, BBNet, BBAICore, BBAI, BBOpenAI, BBGemini, BBExport, BBUI, BBTestSupport) |
| `Spikes/` | Phase 0 live-API spikes |
| `scripts/` | secret scan, git hooks, live-test and fixture scripts, test runner |
| `project.yml` | XcodeGen spec for `BookBook.xcodeproj` |

Documents:

- [`product-description.md`](product-description.md): what BookBook does (source of truth for requirements)
- [`architecture.md`](architecture.md): how it's built
- [`implementation-plan.md`](implementation-plan.md): the phased build plan
- [`PROGRESS.md`](PROGRESS.md): where the build is now

## Licences

The bundled test font, Atkinson Hyperlegible (Regular and Bold, copyright 2020 Braille Institute of America, Inc.), is licensed under the SIL Open Font License 1.1. The licence text is in `BookBookKit/Sources/BBTestSupport/Resources/Fonts/OFL.txt`. The font is used only by tests and is never linked into the app.
