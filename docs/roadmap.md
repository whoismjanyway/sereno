# Roadmap

The project is split into small, separately shippable parts. Each part below is a [GitHub issue](https://github.com/whoismjanyway/sereno/issues), grouped into [milestones](https://github.com/whoismjanyway/sereno/milestones), so anyone can pick one up.

## Done

### 0.1: Tiered menus and refresh coordinator
- [x] Tier engine over KOReader's menu order file (`KOMenu:disabled`)
- [x] Adopt and restore the user's own order file
- [x] Customize levels per item, menu search shortcut, gesture actions
- [x] E-ink refresh coordinator (grouping, shared minute timer, flash policy)

### 0.2: Home screen and book metrics (phase 2)
- [x] Book metrics engine: print model, APNX, Adobe, characters per page; words; readability for en/es/de
- [x] Library-wide metrics cache and Open Library download
- [x] Design system from physical units
- [x] Contextual home layout with a vertical budget, plus SVG previews
- [x] KOReader integration:
  - home widget
  - background counting
  - "Pages & readability" dialog
  - folder counting
  - settings
- [x] Spanish translation, translation completeness spec, CI

## Next

### 0.2.x: Validate on devices
| # | Part | Size |
|---|---|---|
| [#1](https://github.com/whoismjanyway/sereno/issues/1) | Try the home screen on a Kindle (KOReader 2026.x): fonts, covers, taps, refresh | S |
| [#2](https://github.com/whoismjanyway/sereno/issues/2) | Verify `Theme:faceSize` gives the intended pixel sizes on device (photograph a ruler) | S |
| [#3](https://github.com/whoismjanyway/sereno/issues/3) | Time the analyzer on device; yield inside long books if a single count blocks the UI for more than 1 s | M |
| [#4](https://github.com/whoismjanyway/sereno/issues/4) | Night mode: check inverted rendering of covers, rules and greys | S |
| [#5](https://github.com/whoismjanyway/sereno/issues/5) | Calibrate the print model with more reference books whose paperback page count is known | S, ongoing |

### 0.3: Reading data
| # | Part | Size |
|---|---|---|
| [#6](https://github.com/whoismjanyway/sereno/issues/6) | Personal reading speed from KOReader's statistics database instead of a fixed 230 wpm | M |
| [#7](https://github.com/whoismjanyway/sereno/issues/7) | Make KOReader's own "stable page numbers" match Sereno's count. Set the book's synthetic characters per page to `chars / print pages`, so the footer shows the same page numbers as the home screen. | M |
| [#8](https://github.com/whoismjanyway/sereno/issues/8) | Optional "To read" collection as a shelf source | S |
| [#9](https://github.com/whoismjanyway/sereno/issues/9) | Physical Home key opens Sereno's home screen | S |

### 0.4: Reader panel (phase 3)
| # | Part | Size |
|---|---|---|
| [#10](https://github.com/whoismjanyway/sereno/issues/10) | Unified bottom panel in the reader: progress with page preview, contents, font, light | L |
| [#11](https://github.com/whoismjanyway/sereno/issues/11) | D-pad focus for the home screen (non-touch Kindles) | M |
| [#12](https://github.com/whoismjanyway/sereno/issues/12) | Landscape: two-column shelf and hero polish | S |

### Later: Shell API (phase 4)
| # | Part | Size |
|---|---|---|
| [#13](https://github.com/whoismjanyway/sereno/issues/13) | Write a proposal for KOReader: `registerHomeProvider`, `registerNavTab`, `registerQuickControl`, so interface plugins stop patching and can coexist | M |

### Good first issues
| # | Part |
|---|---|
| [#14](https://github.com/whoismjanyway/sereno/issues/14) | Translations: Portuguese, French, German, Italian (one file each in `sereno/l10n/`) |
| [#15](https://github.com/whoismjanyway/sereno/issues/15) | French syllable rules and readability formula (Kandel–Moles) |
