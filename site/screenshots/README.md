# Shrike interface screenshots

These are actual Shrike captures taken from local arm64 Release builds on macOS 26.5.2 in Dark appearance. Six pictures come from a 0.2.33 development build (source 97ce00ee), captured in one session on 14 November 2026. The `browser` and `info-histogram` pictures were retaken on 16 November 2026 with a 0.2.34 development build (source c8589c15) so that they show neutral number and date formats (see below). Later releases may differ in small details.

Sample imagery: NASA/JSC. No NASA affiliation or endorsement is implied. Three distinct Earth observations are used:

- https://images.nasa.gov/details/iss043e000030
- https://images.nasa.gov/details/iss040e030547
- https://images.nasa.gov/details/iss042e013697

The three photos were renamed `Earth 01.jpg` (iss043e000030), `Earth 02.jpg` (iss040e030547) and `Earth 03.jpg` (iss042e013697). For a fuller grid, the `browser` picture also shows 25 crops of these three photos (`Earth 04.jpg` to `Earth 28.jpg`, made with ImageMagick); no other imagery is used.

## Files

Only WebP files are tracked in git. `<name>.webp` is the picture on the page (hero maximum width 2400 pixels, others 1400; never enlarged). `full/<name>.webp` is the Enlarge version (up to 5120 pixels wide). Both are ICC-converted to sRGB, have their metadata removed, and use WebP quality 85. Each picture is a capture of one Shrike window without its shadow. No stretching, retouching or UI compositing was applied, and seven of the eight are not cropped. The exception is `contact-sheet`: the dialog cannot be captured on its own, so it is cut out of the capture of its Browser window at the dialog's own window bounds (the corners show the dimmed window behind it).

The earlier PNG versions (the `full/` files were JPEG data with a `.png` name) are no longer tracked; they stay in the git history.

## Adding or replacing a picture

1. Save the new capture as `site/screenshots/src/<name>.png` (or `.jpg`). `<name>` is one of `viewer`, `browser`, `fullscreen`, `edit`, `info-histogram`, `compare`, `batch`, `contact-sheet`. The `src/` folder is git-ignored: sources are never committed.
2. Run `Scripts/make-screenshots.sh` (needs ImageMagick with WebP support). It writes `<name>.webp` and `full/<name>.webp` and prints their sizes.
3. Check the `width` / `height` attributes in `site/index.html`, update this file (version, source commit, date, hashes), then run `bash Scripts/check-site.sh`.

## Capture and asset identity

The six pictures taken on 14 November 2026 (all except `browser` and `info-histogram`):

- Version: 0.2.33 development build, Release configuration
- Product source: `97ce00ee14862c7c746e8c8dc0922bd200f25ed2`
- App executable SHA256: `09a10a7c1ccdfd174e7663897eac15ddd0e8425666a49342f77efda6efe1b0fd`
- macOS 26.5.2 (25F84), Dark appearance, display at 2× scale

The `browser` and `info-histogram` pictures (retaken on 16 November 2026):

- Version: 0.2.34 development build, Release configuration
- Product source: `c8589c156aec05cbd574c79cb8bbed54c8280c86`
- App executable SHA256: `61a902639c1a4b77c8d8e0053e4711b997efdaa7607df6103b799d8692c04393`
- macOS 26.5.2 (25F84), Dark appearance, display at 2× scale
- The app ran with the time zone set to UTC and the US English locale (`TZ=UTC`, `-AppleLocale en_US -AppleLanguages (en)`, for that process only), so sizes use a decimal point ("2.4 MB") and dates use the US format. The photos had fixed file dates on 16 November 2026, so the Modified row is the same for everyone and shows no local time zone.
- The `info-histogram` window is 1718 × 1209 points instead of 1761 × 1239: the screen used was not tall enough. It has the same shape, so the page picture keeps its 1400 × 985 size.

### batch

- Captured: 14 November 2026
- Raw pixels: 1760 × 1264; display pixels: 1400 × 1005
- `screenshots/full/batch.webp`: 75716 bytes; SHA256 `d78c983e5a2b509528ea6234ba611339b872cc0745fa9f97dba4933101ad30e6`
- `screenshots/batch.webp`: 54550 bytes; SHA256 `8c54e4b6a3c39ac42ae36d60bef464a255fbcbd044f659f5672dd63bd5b5736d`

### browser

- Captured: 16 November 2026
- Raw pixels: 2402 × 1602; display pixels: 1400 × 934
- `screenshots/full/browser.webp`: 285340 bytes; SHA256 `fa82d16405702797309113b1433ed84bab4df2e391bccc5ccba49c3e6b1cdda4`
- `screenshots/browser.webp`: 107468 bytes; SHA256 `cb976a3255535f23bf77f75a1fc86a0d8b15d91ba73e39614dc8bd9224adf3d2`

### compare

- Captured: 14 November 2026
- Raw pixels: 3500 × 1000; display pixels: 1400 × 400
- `screenshots/full/compare.webp`: 453812 bytes; SHA256 `d994bdfcab21a19605ac7fe4c519f72f133f7a22a0be104cb95cc66e0dff9ed4`
- `screenshots/compare.webp`: 78776 bytes; SHA256 `3235ae4a7c6d39d45ab352b74c38638bd6e0a6b44bc840bc26fa29e2c591488c`

### contact-sheet

- Captured: 14 November 2026 (Browser window capture, cut to the dialog's bounds)
- Raw pixels: 1320 × 724 after the cut (window capture 3408 × 2450); display pixels: 1320 × 724
- `screenshots/full/contact-sheet.webp`: 25378 bytes; SHA256 `7a5e7a4b9934f1176c82747d7473fb2ec193af3a60cbb35552a309fda81ad526`
- `screenshots/contact-sheet.webp`: 25378 bytes; SHA256 `7a5e7a4b9934f1176c82747d7473fb2ec193af3a60cbb35552a309fda81ad526` (the same file: the picture is smaller than both size limits)

### edit

- Captured: 14 November 2026
- Raw pixels: 3522 × 2478; display pixels: 1400 × 985
- `screenshots/full/edit.webp`: 751200 bytes; SHA256 `8fc5b5593736da0d182b5f5778f92167691774c64d7a7d12cc6304ea62022e6a`
- `screenshots/edit.webp`: 168972 bytes; SHA256 `2a8d2f93fb19e73cf0fbf5b7a033cadba657bdfeb2616ecf6f7aba0e2e681b18`

### fullscreen

- Captured: 14 November 2026
- Raw pixels: 5120 × 3414; display pixels: 1400 × 934
- `screenshots/full/fullscreen.webp`: 1680348 bytes; SHA256 `81742cd0fa144f579e9045656958609fb16667c71a78b287d68dd2a9cad67cf8`
- `screenshots/fullscreen.webp`: 265512 bytes; SHA256 `8897878f079bc46cb5ba9520416cb3ecb5b862453357be2352e38ecbb8ec1fff`

### info-histogram

- Captured: 16 November 2026
- Raw pixels: 3436 × 2418; display pixels: 1400 × 985
- `screenshots/full/info-histogram.webp`: 868376 bytes; SHA256 `65c1b70eca5ec8bbe7cca626937a4483c56da5e2db3f4c06474e0896d2559afc`
- `screenshots/info-histogram.webp`: 209980 bytes; SHA256 `ba30b7efa3ebc3e2f6d8e75e7fda5d5958f4f3ee2a565d487161985560494643`

### viewer

- Captured: 14 November 2026
- Raw pixels: 3522 × 2478; display pixels: 2400 × 1689
- `screenshots/full/viewer.webp`: 1034006 bytes; SHA256 `f1d3059e4539c3041b59f5eaa36152413cc92a5fbfb2ef9603c3f500f8203e75`
- `screenshots/viewer.webp`: 584950 bytes; SHA256 `41397d8eba069a9decc3d988dcce07bce43731743ea367c19354da2886447343`
