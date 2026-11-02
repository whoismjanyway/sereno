# Sereno

**A calmer interface for [KOReader](https://koreader.rocks), without patching KOReader.**

Sereno is a KOReader plugin with three parts:

- **A contextual home screen** designed from the physical size of your screen, not its pixel count.
- **Print-like page counts, word counts and readability** for every book in your library, computed without opening the books.
- **Tiered menus** that hide what you don't need, using KOReader's own menu-order mechanism.

![The home screen while reading, after finishing a book, and before starting one](docs/images/states.png)

*Home screen previews rendered by `tools/preview.lua` (Kindle Paperwhite 5, 300 dpi). On a device, CoverBrowser's real covers replace the typeset ones.*

## Why another interface plugin?

[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and [ZenOS](https://github.com/xZenLabs/zen-os) both made KOReader friendlier. Sereno tries to fix what they share:

| | SimpleUI / ZenOS | Sereno |
|---|---|---|
| **How it hooks in** | They patch KOReader internals (CoverBrowser), so they can't be installed together and break when KOReader changes. | It uses only public extension points: the per-user menu order file, file-dialog buttons, dispatcher actions and its own widget. |
| **Sizing** | Pixel-based, through KOReader's `scaleBySize`. The same theme looks big on a 6" Kindle and small on a 10" Scribe. | Millimetres and points: the same printed text size on every device. There is a modular type scale, 6 mm minimum margins and 7 mm touch targets. |
| **Home screen** | A dashboard of many widgets. | One focal point (the book you're reading) and a shelf. The layout adapts to the screen instead of overflowing. |
| **E-ink** | Each widget refreshes on its own. | One coordinator groups refreshes. Only the clock line repaints, once a minute, and pauses during sleep. |
| **Page numbers** | Whatever KOReader shows, which changes with every font change. | A stable *print-model* count, the same for every reading setting. See [Page counts](#page-counts). |

## Page counts

KOReader numbers pages as they are laid out on your screen. Change the font size and *page 120 of 340* becomes *page 180 of 512*. Its synthetic page map, which cuts the text every 1500 characters, is stable but only exists once a book has been opened.

Sereno reads the EPUB directly and estimates pages the way [Calibre's Count Pages](https://github.com/kiwidude68/calibre_plugins/wiki/Count-Pages) does, so it works for a whole library at once. It adds its own estimator:

- **Print model** (default): Sereno *typesets* the book on a reference paperback page (64 characters × 32 lines).
  - Words wrap; every paragraph starts a new line.
  - Headings and images take room; chapters start on a fresh page.
  - Dialogue-heavy and illustrated books therefore get the extra pages they really use in print.
- **Printed edition**: downloaded from Open Library, either for the book's ISBN or as the median of all editions of the work.
- **Calibre APNX**, **Adobe Digital Editions** and **characters per page (1500)**: re-implementations of the classic estimators, kept for comparison.

The book's position is mapped onto the chosen count, so the home screen says *Page 68 of 179 · 38%*, and keeps saying it whatever font you pick.

| Book (Standard Ebooks) | Print model | APNX | Adobe | 1500 chars | Words | Readability |
|---|---|---|---|---|---|---|
| The Great Gatsby | **179** | 181 | 132 | 180 | 49,153 | Fairly easy (Flesch 75) |
| Pride and Prejudice | **434** | 386 | 354 | 457 | 122,692 | Standard (64) |
| Frankenstein | **268** | 229 | 220 | 293 | 78,619 | Fairly demanding (60) |
| Treasure Island | **247** | 218 | 209 | 242 | 69,109 | Easy (80) |
| Alice's Adventures in Wonderland | **125** | 101 | 87 | 101 | 28,116 | Easy (81) |

The Scribner paperback of *The Great Gatsby* has 180 pages. Each count takes 0.1–0.2 s on a desktop computer. Details and calibration are in [docs/page-count.md](docs/page-count.md).

**Readability** uses the formula made for each language:
- **English:** Flesch, Flesch–Kincaid and Gunning Fog
- **Spanish:** Szigriszt-Pazos on the INFLESZ scale
- **German:** Amstad

Long-press a book in the file browser, or hold it on the home screen, to see every number side by side.

## Install

1. Download this repository, or a release, and copy the `sereno.koplugin` folder into KOReader's `plugins/` folder.
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/`
2. Restart KOReader.
3. Open **Settings → Sereno**:
   - **Home screen** shows it now. You can also turn on *Start with the home screen*.
   - **Page counts → Count all books in this folder** counts the whole library once.
   - **Tiered menus** lets you choose *Reading*, *Everyday* or *Everything*.

The cover art on the home screen comes from KOReader's CoverBrowser plugin, which is on by default. To uninstall, turn tiered menus off first (that restores your own menu order file), then delete the folder.

> **Status:** 0.2, early. Everything is covered by tests run on LuaJIT with KOReader stubs, and by layout previews for several devices, but **it has not yet been tried on a real device**. Please report what you see; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Develop

```sh
git clone --depth 1 https://github.com/koreader/koreader.git ../koreader   # optional: real default menus
KOREADER_DIR=../koreader luajit spec/run.lua                               # all specs
luajit tools/count.lua path/to/book.epub                                   # page counts from the command line
luajit tools/preview.lua previews && rsvg-convert -o p.png previews/paperwhite-reading.svg
```

- **Code layout:** [docs/architecture.md](docs/architecture.md)
- **Design decisions:** [docs/design.md](docs/design.md)
- **What's next, broken into small parts:** [docs/roadmap.md](docs/roadmap.md)

## Credits and license

- **Algorithms:** the APNX, Adobe and characters-per-page estimators follow Grant Drake's Count Pages plugin for Calibre (GPL-3.0).
- **Prior work:** thanks to the KOReader, SimpleUI and ZenOS projects for showing what people want from their e-readers.
- **License:** Sereno is licensed under the AGPL-3.0, like KOReader.
