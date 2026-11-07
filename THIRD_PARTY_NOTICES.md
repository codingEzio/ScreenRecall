# Third-party notices and dependency provenance

The candidate's owner-authored code uses GPL-3.0-only; see `LICENSE_SCOPE.md`.
Third-party material below keeps its original licenses. These notices apply to
the explicit source candidate, not private repository history or user data.

## libwebp and sharpyuv

- Use: `RecallCore` links to `libwebp`; the staged app bundles `libwebp.7.dylib`
  and `libsharpyuv.0.dylib` from the Homebrew `webp` formula. The bundle script
  also copies the formula's `COPYING` file to `Resources/libwebp-COPYING.txt`.
- Verified local build input: Homebrew formula `webp` 1.6.0, BSD-3-Clause,
  source archive `https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.6.0.tar.gz`,
  SHA-256 `e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564`.
- Copyright attribution in the upstream license: Google Inc., 2010. Preserve
  the upstream copyright, conditions, and disclaimer with binary distributions.
- Upstream references: [COPYING](https://chromium.googlesource.com/webm/libwebp/+/v1.6.0/COPYING)
  and [PATENTS](https://chromium.googlesource.com/webm/libwebp/+/v1.6.0/PATENTS).
  The exact v1.6.0 texts are retained in `Licenses/libwebp-1.6.0-COPYING.txt`
  and `Licenses/libwebp-1.6.0-PATENTS.txt`. Both are copied into prepared app
  bundles. The script refuses other pkg-config versions before compilation so
  these fixed notices cannot silently describe a different encoder.

## DeparturePixelZh Compact

- Use: the app stages `DeparturePixelZhCompact-Regular.ttf` into
  `Contents/Resources/Fonts/` and copies `OFL.txt`, `NOTICE.md`, `provenance.json`,
  and every file from the bundled producer `Licenses/` directory into the app
  bundle. The source candidate includes the pinned font and its notices under
  `Dependencies/DeparturePixelZh`.
- Verified font identity: DeparturePixelZh Compact; PostScript name
  `DeparturePixelZhCompact-Regular`; expected font SHA-256
  `74adf4919c690e61aa7bdd4c369a6f5c84029413a7da5e85d687ea7fa6b502e7`.
  `CompactFontTests.swift` checks that hash and the expected family and glyphs.
- License: the producer notice identifies this modified font family as SIL Open
  Font License 1.1. Keep the producer's `OFL.txt`, `NOTICE.md`, and complete
  `Licenses/` directory with redistributed or embedded font files.
- The producer's original build input was `X-DeparturePixelZh/Build`; its
  retained `provenance.json` pins the source inputs, archive/content hashes,
  font output hashes, and builder revision. Building this candidate uses its
  bundled copy and does not require the sibling checkout. It retains the original
  provenance and all 25 license files. Font-source rebuilding and a public download for this exact
  historical artifact were not verified in this preparation.
- Recorded upstream font inputs in the producer provenance:
  - Departure Mono 1.500, OFL-1.1: `https://github.com/rektdeckard/departure-mono/releases/download/v1.500/DepartureMono-1.500.zip`.
  - Cubic 11 embedded version 1.451, with the exact pinned root OFL text and inherited notices: pinned source at
    `https://raw.githubusercontent.com/ACh-K/Cubic-11/4c566f7d6cc5c05ee360fe9cff56b5da1fcafd4d/fonts/ttf/Cubic_11.ttf`.
  - Nerd Fonts Symbols Mono 3.5.1: `https://github.com/ryanoasis/nerd-fonts/releases/download/v3.5.1/NerdFontsSymbolsOnly.zip`.
    The producer notice records the included Codicons, Devicons, Hack, Font
    Awesome, Font Awesome Extension, Font Logos, Material Design Icons,
    Octicons, Seti, Pomicons, Powerline, Power Symbols IEC, and Weather Icons
    notices and their respective licenses. Retain those source notices; do not
    treat the assembled font as a license for the ScreenRecall source code.

The retained producer summary incorrectly calls this Cubic input “1.500”.
`FONT_NOTICE_CORRECTIONS.md` records the pinned 1.451 version and verified root
license URL/hash; its exact full license bytes remain unchanged. This statement
applies only to that historical font input, not every Cubic release.

## Compatibility and release boundary

The WebP BSD-3-Clause copyright/conditions/disclaimer and additional patent grant
are retained intact; the encoder is not relicensed. GPL version 3 permits this
permissively licensed dependency when its conditions are preserved. The OFL
font is supplied as a separate, unmodified resource with its complete inherited
notices; it is not GPL software and its separate licensing remains visible.
SQLite and Apple frameworks are linked from macOS, not redistributed here.
The selected original icon SVGs use CC BY 4.0 as listed in `ARTWORK.md`.

This is source preparation, not signed-binary distribution or clearance for the
private Git repository/history. The prior isolated build evidence remains bound
to unchanged compiled sources; the new license-copy path is checked separately
with an isolated bundle fixture. No app launch, recording or live-data access
is part of that verification.

## Local preparation — 2026-10-21

The application font pin is unchanged. The current producer build has a different
hash, so it is not substituted. The retained reviewed 0.1.0 font artifact records
builder revision `0bd24fd18f8c5aea5b2d238ee553a30cfd66c1a1`; the candidate copies
only the pinned Compact TTF, OFL.txt, NOTICE.md, provenance.json and the complete
25-file license set. Each input hash is fixed in the maintainer's public-source.json.
Duplicate nested copies in the retained input were byte-compared and are not
needed in the candidate; original input contents remain unchanged.

The unsigned app preparation now copies both pinned upstream WebP notices, the
GPL text/scope and artwork terms. The source candidate carries those exact
inputs. System SQLite and Apple frameworks remain system prerequisites.

繁中：自有程式採 GPL-3.0-only，原創圖層依 ARTWORK.md 採 CC BY 4.0；
WebP、字型與其衍生內容維持原授權，附完整聲明。未發布、安裝或啟動。
简中：自有代码采用 GPL-3.0-only，原创图层按 ARTWORK.md 采用 CC BY 4.0；
WebP、字体及其衍生内容保持原许可，附完整声明。未发布、安装或启动。
