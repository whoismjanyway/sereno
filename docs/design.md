# Design notes

## Start from the physical screen

KOReader sizes interface fonts with `Screen:scaleBySize`, which multiplies by `min(width, height) / 600` and ignores DPI unless the user overrides it. The same "size 24" font therefore ends up very different on different devices:

| Device | Screen | KOReader UI body text |
|---|---|---|
| Kindle (2019) | 600 px wide at 167 dpi | 24 px ≈ 10 pt |
| Kindle Scribe | 1860 px wide at 300 dpi | 75 px ≈ 18 pt |

`sereno/ui/theme.lua` starts from millimetres and points instead:

- **Body size** comes from the screen diagonal: 10 pt below 6.5", 10.5 pt up to 7.5", 11 pt up to 9", 12 pt above.
- **Type scale:** a major third (×1.25).
  - **micro** (−2): running heads and meta.
  - **caption** (−1): status and shelf titles.
  - **body**.
  - **title** (+2).
  - **headline** (+3): the book you're reading.
  - **display** (+5): reserved.
- **Leading:** 1.35 for body text, tightening to 1.05 for display sizes.
- **Spacing:** one baseline unit of 1.5 mm. Every gap is a multiple of it.
- **Margins:** at least 6 mm. On large screens the content column is capped at 110 mm (portrait) or 180 mm (landscape), so lines stay readable and the margins grow instead.
- **Grid:** 6 columns (8 on large or landscape screens) with 4 mm gutters.
- **Touch targets:** at least 7 mm high.
- **Ink:** black text, plus only two greys, `#444` and `#888`. Light-grey text dithers badly on 16-level panels, so there is none.
- **Fonts:** serif (Noto Serif) for book titles, like a cover or a title page, and sans (Noto Sans) for interface text. Both ship with KOReader.

To get exact pixel sizes through `Font:getFace`, the theme divides by KOReader's scale factor (`Theme:faceSize`).

## One focal point

The home screen answers one question first, "where was I?", and then offers a few next books. It is contextual rather than a grid of widgets:

| State | Hero | Shelf |
|---|---|---|
| Reading | The current book: page *n of N* in stable print pages, a progress rule, time left at your reading speed, readability | "On your shelf": other books in progress, then new ones |
| Finished | The book you finished: its length and reading time, and "Next: …" | "Up next": the next book in the series, then new books |
| Start | The newest unread book | "Up next" |
| Empty | A short note on how to add books | — |

## Fit the screen, never overflow

`sereno/home/layout.lua` works to a vertical budget. It first reserves at least one shelf row, then tries hero variants from generous to compact until one fits:

1. 3-line title, full cover
2. 2-line title
3. smaller cover, no detail line
4. smaller title style
5. smallest cover

Gaps tighten (6 → 4 → 3 units) before content is dropped. Shelf covers may shrink to 60 % before the shelf disappears. A long title drops its subtitle ("Frankenstein; or, The Modern Prometheus" → "Frankenstein") rather than being cut mid-phrase.

On a device the layout measures text with KOReader's own shaping (`TextBoxWidget`), so the boxes match the glyphs. In previews and tests it uses an estimate. `spec/home_spec.lua` checks every state on seven screen sizes for nodes that leave the screen or overlap, and that both the hero and the shelf are present.

## Refresh as a budget

E-ink refreshes are slow and visible. The home screen paints once with a `flashui` refresh on open, then only the status line changes: one `ui` refresh a minute, driven by the shared, minute-aligned timer in `sereno/eink/refresh.lua`. The timer pauses while the device sleeps or another window covers the home screen. Counting books in the background triggers a single repaint at the end, not one per book.

## Copy

- **Plain words:** *Continue reading*, *About 2 h 13 min left*, *Fairly easy read*. No icons where a word is clearer.
- **Translatable as a whole:** all strings go through `sereno/l10n`, and a spec checks every translation is complete and keeps its placeholders.
