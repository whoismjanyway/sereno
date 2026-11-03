<p align="center"><img src="docs/images/brand/sereno-logo.svg" alt="Sereno" width="300"></p>

# Sereno

**A calmer interface for [KOReader](https://koreader.rocks), without patching KOReader.**

Sereno is a KOReader plugin that replaces the interface you see every day:

- **A complete shell:** Home, Library, Reading, Collections and Search behind one tab bar. You never fall back into KOReader's file browser unless you ask for it.
- **Quick controls:** swipe down from the top edge for Wi-Fi, night mode, the light, rotation, restart, sleep, and brightness and warmth sliders.
- **One settings screen:** Sereno's own tab (the book mark) next to all of KOReader's tabs, unchanged, so every KOReader option still works and nothing Sereno adds gets mixed into KOReader's pages.
- **Sleep screens that keep working:** KOReader's own sleep screen options (covers, your images and folders, messages) are untouched, and Sereno adds an optional cover-and-progress sleep screen.
- **Bars in the book:** tap the top or bottom of a page for a toolbar (Home, text & page, contents, bookmarks, search, KOReader's menu) and a progress bar with chapter marks, chapter skips and *Back to page …*.
- **A contextual home screen** designed from the physical size of your screen, not its pixel count.
- **Print-like page counts, word counts and readability** for every book in your library, computed without opening the books.
- **Tiered menus** that hide what you don't need, using KOReader's own menu-order mechanism.

![Home, Library, quick controls and the bars in a book, on a Kindle Paperwhite](docs/images/shell/shell-paperwhite.png)

![The home screen while reading, after finishing a book, and before starting one](docs/images/states.png)

![The same home screen on a 6" Kindle, a Kindle Scribe and a colour screen](docs/images/devices.png)

![The home screen drawn by KOReader's own widget code on a Paperwhite, a 6" Kindle and a Scribe](docs/images/real-devices.png)

*The last row is not a mock-up. `tools/korender` draws it with KOReader's own blitbuffer, FreeType fonts, TextBoxWidget and IconWidget, and Sereno's HomeScreen widget.*

*Previews rendered by `tools/preview.lua`: a Kindle Paperwhite 5 (top), then a 6" Kindle, a Kindle Scribe and a colour e-ink screen. The covers are the real ones, taken out of each EPUB by Sereno's own reader, from [Standard Ebooks](https://standardebooks.org) editions.*

**What's on the screen**, from top to bottom:
- **Header:** a greeting in serif and the date. Small screens get a single line with the date, clock and battery.
- **Book card:** the book you're reading, with its real cover and a progress bar. Short facts sit in chips: *Page 68 of 179*, *2 h 13 min left*, the readability.
- **Library tiles:** books being read, unread and finished. They become one line, or disappear, when space is short.
- **Shelf:** real covers, with progress bars on books in progress, and *See all* to open the library. Large screens get two rows.
- **Tab bar:** KOReader's own icons with words under them; the active tab is marked.

## Getting around

| Where | Gesture | What you get |
|---|---|---|
| Anywhere in Sereno | Tap a tab | Home, Library (folders and covers), Reading (books in progress first), Collections, Search |
| Library and other tabs | Swipe ← / → | Next or previous page of covers (e-ink pages, no scrolling) |
| Library | Tap *Title ▾* | Sort by title, author or most recent |
| Any book | Hold | Pages, words and readability |
| Top edge, anywhere | Swipe ↓ (or tap the clock line) | Quick controls |
| In a book | Tap the top or bottom of the page | Sereno's bars; tap the middle of the page to hide them |
| Quick controls | *KOReader menu* / *File browser* | KOReader's own menu and file browser, whenever you need them |

Everything goes through KOReader's public extension points: the bars are touch zones registered on the reader before KOReader's menu zones, the quick controls send KOReader's own events (`ToggleWifi`, `ToggleNightMode`, `IterateRotation`, …), and the shell is a full-screen window over the file manager. Turn off *Settings → Sereno → Sereno's bars in books* to get KOReader's menus back.

![The same screens on a 6" Kindle](docs/images/shell/shell-kindle-basic.png)

### Settings and sleep screen

Open **Settings** from the quick controls (or ⋮ in a book). The first tab, with Sereno's mark, holds Sereno's options: Home screen, Reader, Sleep screen, Tiered menus, About. The tabs after it are KOReader's own menu, exactly as KOReader builds it.

**Sleep screen.** Sereno never draws over KOReader's sleep screen: KOReader draws it before it tells plugins the device is going to sleep. Sereno only pauses its clock and closes its sheets, then redraws in full on wake. *Sleep screen → Sereno: cover and progress* shows the book you're reading, with its cover, title and progress. It uses KOReader's own "random image from a folder" mode on a folder Sereno keeps up to date, so turning it off gives you back the sleep screen you had. *KOReader's sleep screen options* is KOReader's own menu.

![Settings with Sereno's tab first, and Sereno's sleep screen](docs/images/shell/settings-kindle-basic.png)

## Why another interface plugin?

[SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) and [ZenOS](https://github.com/xZenLabs/zen-os) both made KOReader friendlier. Sereno tries to fix what they share:

| | SimpleUI / ZenOS | Sereno |
|---|---|---|
| **How it hooks in** | They patch KOReader internals (CoverBrowser), so they can't be installed together and break when KOReader changes. | It uses only public extension points: the per-user menu order file, file-dialog buttons, dispatcher actions and its own widget. |
| **Sizing** | Pixel-based, through KOReader's `scaleBySize`. The same theme looks big on a 6" Kindle and small on a 10" Scribe. | Millimetres and points: the same printed text size on every device. There is a modular type scale, 6 mm minimum margins and 7 mm touch targets. |
| **Home screen** | A dashboard of many widgets. | One focal point (the book you're reading) and a shelf. The layout adapts to the screen instead of overflowing. |
| **E-ink** | Each widget refreshes on its own. | One coordinator groups refreshes. Only the clock line repaints, once a minute, and pauses during sleep. |
| **Page numbers** | Whatever KOReader shows, which changes with every font change. | A stable *print-model* count, the same for every reading setting. See [Page counts](#page-counts). |

## Fonts, text size and margins

Sereno sizes everything in points and millimetres, then converts to pixels with the screen's DPI. Text therefore prints at the same size on a 167 dpi Kindle and a 300 dpi Paperwhite, and big screens get wider margins instead of giant letters.

**Text size.** Below, body text is drawn at real size on four devices. KOReader's default interface text grows with the pixel count: 10.3 pt on a 6" Kindle, 18 pt on a Kindle Scribe. Sereno picks 10–12 pt by screen diagonal.

![Body text at real size: KOReader's default vs Sereno, on four devices](docs/images/design/physical-size.png)

**Fonts.** Every style comes from one scale: each step is 1.25× the previous one, around the body size.

| Font | Used for |
|---|---|
| Noto Serif | Book titles, the greeting and the counts, like a cover or a title page |
| Noto Sans | Everything else |

Both fonts ship with KOReader.

![The type scale: display, headline, title, body, label, caption and micro, with sizes and leading](docs/images/design/type-scale.png)

**Margins and grid.** The content sits in a column with at least 6 mm of margin, capped at 110 mm wide so lines stay readable on large screens.

| | Small screens | Large screens |
|---|---|---|
| Grid | 6 columns | 8 columns |
| Gutter | 4 mm | 4 mm |

All vertical spacing is a multiple of 1.5 mm, and touch targets are at least 7 mm high.

![Margins and columns of four devices, drawn to the same scale](docs/images/design/margins.png)

The overlay below is drawn on the real home screen, on a Kindle Paperwhite and on a 6" Kindle:
- **Red:** margins
- **Blue:** grid columns
- **Cyan lines:** the 1.5 mm baseline unit
- **Green dashes:** touch targets

![Design grid over the home screen: margins, columns, baseline unit and touch targets](docs/images/design/grid.png)

To make these images yourself, run `luajit tools/specimen.lua out/`. For the overlays, run `SERENO_PREVIEW_GRID=1 luajit tools/preview.lua out/ books/`. There is more in [docs/design.md](docs/design.md).

## The page you read

KOReader sets the reader's font size and margins in "relative pixels" that grow with the screen's pixel count. With its defaults:

| Device | Text | Side margins |
|---|---|---|
| 6" Kindle | 9.5 pt | 1.5 mm |
| Paperwhite 5 | 11 pt | 1.8 mm |
| Kindle Scribe | 16.6 pt | 2.6 mm |

So the text runs almost to the bezel on every device, and changes size from one device to the next. Sereno sets the page like a printed book instead: 8 mm margins, a book-like leading of 1.5, indented paragraphs, justified and hyphenated lines, and chapters that open lower on the page.

![KOReader's default page next to Sereno's Normal page on a 6" Kindle, a Paperwhite and a Scribe](docs/images/design/reader-margins.png)

### The Text panel: Themes, Font, Layout

Tap *Aa* in the bar at the top of a book (or *Font, size and page (Sereno)* in KOReader's typeset menu). The panel has three tabs, like the Kindle's, and reopens on the last one you used. Each tap re-flows the book behind it straight away, and new books open the same way.

| Tab | What's in it |
|---|---|
| **Themes** | Compact, Standard and Large, and your own: *Save current settings* keeps the font, size, bold, page and alignment under a name. Hold a theme you saved to delete it. |
| **Font** | *Font family*, written in its own typeface; tap it for a list of every font, each shown in itself. *Bold* as a bar of five boxes (KOReader's font weight). *Size* as a numbered bar of 14 boxes, with − and +. |
| **Layout** | *Page*: Compact, Normal or Roomy (margins of 5, 8 or 14 mm with matching line spacing; on big screens the margins grow so lines stay readable). *Alignment*: justified or left. |

![Themes, Font, the font list and Layout on a Kindle Paperwhite](docs/images/design/reader-panel-tabs.png)

**Selecting text.** Holding on text gives a short menu: *Highlight*, *Note*, *Dictionary* and *More…*, which holds everything else (copy, search, Wikipedia, translate, and buttons other plugins add). It's built with KOReader's own `addToHighlightDialog` and `removeFromHighlightDialog`; turn off *Settings → Sereno → Reader → Short selection menu* for KOReader's full list. A single word still opens KOReader's dictionary.

Book-style paragraphs (indented first lines, no blank lines between paragraphs, centred headings, hyphenation) are on by default; it's a switch in *Settings → Sereno → Reader*, next to *Back to KOReader's defaults*.

The three pages on a Paperwhite:

![Compact, Normal and Roomy on a Kindle Paperwhite](docs/images/design/reader-layouts.png)

The base text size depends on the screen: 10 pt on 6", 10.5 pt on 7", 11.5 pt on 8", 13.5 pt on larger screens.

*These pages are set by `tools/korender` with KOReader's own font renderer and crengine's hyphenation patterns, the way crengine sets them: greedy line filling, spaces that may condense to 75 %, 1.2 em indents. crengine itself isn't built there, so a line may break differently on a device.*

### Page numbers that don't move

A Kindle can't number pages the way a printed book does: change the font or line spacing and one printed page may spread over several screens, or several over one. KOReader's ordinary page numbers count *screens*, so *page 120 of 340* becomes *page 180 of 512* when you make the text bigger.

Sereno numbers your position by the **text** instead, so it never changes with your settings. You choose how it's shown in *Settings → Sereno → Reader → Page counts*:

| Show | Example | How it's counted |
|---|---|---|
| **Pages** (default) | Page 68 of 179 | The book's print-like page count (see below), laid onto KOReader's character-based page map |
| **Locations**, like a Kindle | Location 452 of 3,400 | One location every 128 characters of text, as Kindle locations are 128-byte blocks |

Both are counted from crengine's own page map, which cuts the text by characters, not by screens. The home screen, the bars in the book, the status bar and *Go to page* all use the same numbers. Books whose publisher included real page numbers keep them.

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

1. Download `sereno.koplugin.zip` from the [latest release](https://github.com/whoismjanyway/sereno/releases/latest), unzip it, and copy the `sereno.koplugin` folder into KOReader's `plugins/` folder.
   - **Kindle:** `/mnt/us/koreader/plugins/`
   - **Kobo:** `/mnt/onboard/.adds/koreader/plugins/`
2. Restart KOReader.
3. Open **Settings → Sereno**:
   - Sereno's home screen opens at start-up (turn off *Start with the home screen* to keep KOReader's file browser).
   - In a book, tap *Aa* in the bar at the top to choose the font, size and page.
   - **Page counts → Count all books in this folder** counts the whole library once.
   - **Tiered menus** lets you choose *Reading*, *Everyday* or *Everything*.

Covers come from KOReader's CoverBrowser cache when that plugin is on. Otherwise Sereno renders the cover image stored inside the EPUB itself, keeping at most 16 in memory. To uninstall, turn tiered menus off first (that restores your own menu order file), then delete the folder.

> **Status:** 0.3, early. **It has not yet been tried on a real device.** What has been checked:
> - **Specs:** 186 of them, run against KOReader's latest release, run on LuaJIT with stubs of KOReader's modules.
> - **Real widget code:** the home screen is also drawn by KOReader's own code (blitbuffer, FreeType fonts, TextBoxWidget, IconWidget) on every CI run, with `tools/korender`.
> - **Previews:** layout previews for several devices. Please report what you see; see [CONTRIBUTING.md](CONTRIBUTING.md).

## Develop

```sh
git clone --depth 1 https://github.com/koreader/koreader.git ../koreader   # optional: real default menus
KOREADER_DIR=../koreader luajit spec/run.lua                               # all specs
luajit tools/count.lua path/to/book.epub                                   # page counts from the command line
luajit tools/preview.lua previews && rsvg-convert -o p.png previews/paperwhite-reading.svg
KORENDER_READER=1 tools/korender/run.sh out/ books/                       # draw with KOReader's real widgets (+ reader pages)
```

- **Code layout:** [docs/architecture.md](docs/architecture.md)
- **Design decisions:** [docs/design.md](docs/design.md)
- **What's next, broken into small parts:** [docs/roadmap.md](docs/roadmap.md)

## Credits and license

- **Algorithms:** the APNX, Adobe and characters-per-page estimators follow Grant Drake's Count Pages plugin for Calibre (GPL-3.0).
- **Prior work:** thanks to the KOReader, SimpleUI and ZenOS projects for showing what people want from their e-readers.
- **Sample books:** the preview covers come from [Standard Ebooks](https://standardebooks.org). Their cover art is in the public domain, and their cover designs are dedicated to the public domain under CC0.
- **Icons:** the tab bar uses KOReader's own icon set.
- **License:** Sereno is licensed under the AGPL-3.0, like KOReader.
