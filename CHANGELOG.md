# Changelog

## 0.5.0 (2026-11-04)

### Added
- **A book page:** the book's title in spaced capitals at the top of every page and the page number centred at the foot, as in a printed book, with margins to hold them. Drawn as a KOReader view module; KOReader's status bar is hidden meanwhile and given back when you choose *Layout → Page style → Status bar*.
- **Stats tab:** from KOReader's own Reading statistics: the book you're reading (days of reading, time read, progress, time left at your own pace), pages a day and time a day over the last week, days in a row, today's pages and time, the last seven days as bars, and all-time totals. Read-only; Sereno never writes to KOReader's database.
- **Import tab:** books from calibre over Wi-Fi (KOReader's calibre plugin) and online catalogs (KOReader's OPDS browser: Project Gutenberg, Standard Ebooks, your calibre content server, catalogs you add).
- **Send books from a browser, over Wi-Fi, without leaving KOReader:** the reader shows an address and a code; open it on a computer or phone on the same Wi-Fi and drop books in. A small upload server (`sereno/transfer/`) runs only while that screen is open, keeps the reader awake, opens and closes the Kindle's firewall port, accepts only e-book files and writes each one under a temporary name until it has arrived whole.
- **By cable:** on a Kobo, KOReader's USB drive mode from the Import tab. On a Kindle, whose USB drive mode only works outside KOReader, Sereno explains the steps and closes KOReader for you.

### Fixed (from testing 0.4 on a Kindle)
- **Exit didn't leave KOReader.** KOReader quits once no window is open; its Exit closed the file manager but Sereno's home screen stayed open, so KOReader kept running. Sereno's windows now close with the file manager, and the quick controls have an *Exit* button.
- **KOReader's file browser showed after reading.** After a book closed, Sereno opened its home screen a moment after KOReader had painted its file browser. It now opens while KOReader is showing the file manager (on its Show event), before anything is painted.

### Changed
- The tab bar is Home, Library, Reading, Stats, Import and Search; Collections are the Library's first tile.

## 0.4.0 (2026-11-03)

### Added
- **Text panel in three tabs, like the Kindle's:** *Themes* (Compact, Standard, Large, and your own saved settings; hold to delete), *Font* (font family written in its own typeface, with a list of every font; *Bold* bar over KOReader's font weight; numbered *Size* bar) and *Layout* (page and alignment). It reopens on the last tab, and new books open with the same settings.
- **Short selection menu:** Highlight, Note, Dictionary and More… (everything else, other plugins' buttons included), through KOReader's public highlight-dialog hooks. One switch brings back KOReader's full list.
- **Kindle-style locations:** *Page counts → Show locations* shows "Location 452 of 3,400" (one per 128 characters of text) on the home screen, in the bars and on the sleep screen.

### Fixed (from testing on a Kindle)
- **"Could not count this book: no META-INF/container.xml" on every EPUB.** KOReader's archive reader only finds files after walking through the archive once; Sereno asked for them straight away. EPUBs are now read the way KOReader's own code reads them (`sereno/archive.lua`), with the device's `unzip` as a fallback. Covers without CoverBrowser had the same problem and are fixed too.
- **"Page numbers can only be set for reflowable books" on EPUBs.** The function Sereno used exists only in KOReader's development version. On releases, Sereno now builds the page map itself through KOReader's "characters per page", searching for the value that gives the book exactly its page count.
- **Home from a book no longer quits to the Kindle's own home screen.** When KOReader was started straight into a book, closing the reader left nothing open and KOReader quit. Sereno now leaves the book the way KOReader's own Home does, which opens the file manager and so Sereno's home screen.
- **Rotation:** the home screen redoes its layout for the new shape.
- **Chapter arrows:** the *previous chapter* arrow is dimmed at the first chapter (the *next* one was dimmed by mistake).

### Changed
- **Page numbers that don't move, on by default:** the reader's numbers come from KOReader's character-based page map, tuned to Sereno's page count, so they stay the same whatever the font, size or margins.
- **Simpler page counts menu:** pages or locations, *Count pages* (one submenu for the method), reading speed, and this book's numbers. The two switches for page numbers are gone: they are always on, applied when a book opens and again if you change the method.
- **Simpler reading settings:** the four 0.2 presets are replaced by the panel's themes and three pages (Compact, Normal, Roomy). Earlier settings carry over. *Justified text* and *Book-style paragraphs* are switches in Settings, next to *Back to KOReader's defaults*.
- **Tests and CI run against KOReader's latest release**, not its development version, with a check that every KOReader function Sereno calls exists there.

## 0.3.0 (2026-11-02)

### Added
- **A complete shell:** the tab bar's Library, Reading, Collections and Search open Sereno screens instead of KOReader's file browser. The Library shows folders as tiles and books as covers, with a page of covers per screen (swipe to turn) and sorting by title, author or date. Reading lists books in progress first. Collections show KOReader's collections and Favorites. Search looks through titles, authors and file names.
- **Quick controls:** swipe down from the top edge (home, library or book) for Wi-Fi, night mode, the light, rotation, restart and sleep, brightness and warmth sliders, and buttons to Settings and KOReader's file browser.
- **Bars in the book:** a tap at the top or bottom of a page shows a toolbar (Home, text settings, contents, bookmarks, search, settings) and a bottom bar with the chapter, the page in Sereno's numbers, a progress slider with chapter marks, chapter skips and *Back to page …* after a jump. Registered as touch zones before KOReader's own menu zones; one setting turns it off.
- **One settings screen:** Sereno's tab (with its mark) first, then KOReader's own menu tabs, unchanged. Opened from the quick controls (*Settings*), ⋮ in a book, a gesture, or Settings → Sereno.
- **Sleep screen:** Sereno's sheets close and its clock stops before sleep, and the screen is redrawn in full on wake, so KOReader's sleep screens show cleanly. A new optional *Sereno: cover and progress* sleep screen uses KOReader's own folder mode and restores the previous choice when turned off. KOReader's sleep screen menu is reachable from Sereno's settings.
- **Logo:** an open book drawn in one stroke, used as the settings tab icon, on the sleep screen and in the README.
- **Shared painter** (`sereno/ui/painter.lua`) for every Sereno screen, with drawn symbols for what KOReader's icon set lacks.

### Changed
- The home screen now opens at start-up by default.
- The *History* tab is now *Reading*.
- Background counting redraws the home screen reliably, even when a cover lookup counted a book first.

## 0.2.0 (2026-11-02)

### Added
- **Text & page panel:** a Kindle-style bottom sheet in the reader with layouts, text size, spacing, margins, alignment and paragraph style, each shown as a miniature page. It opens from the reader's typeset menu, Sereno's menu or a gesture, and re-flows the book with each tap.
- **Book typography:** first-line indents, no blank lines between paragraphs, centred headings, no widows or orphans and hyphenation, through KOReader's own style tweaks. The user's previous tweaks are kept and restored.
- **Reading layouts:** Compact, Paperback, Airy and Large print are defined in points, millimetres and a maximum line length. They apply to the open book through KOReader's own events and become the default for new books. The user's previous defaults are kept and can be restored.
- **Print page numbers in the reader:** KOReader's stable page numbers are tuned to Sereno's page count, so the status bar and *Go to page* match the home screen. Publisher page numbers are kept.
- **`tools/korender`:** draws the home screen, and sample reader pages, with KOReader's real widget code. It runs in CI.
- **Redesigned home screen:**
  - A greeting header.
  - The current book in a card, with its real cover and fact chips.
  - Library tiles (reading, unread, finished).
  - A shelf of covers with progress bars, and *See all*.
  - A tab bar with KOReader's icons.
  - The layout degrades step by step on small screens and adds a second shelf row on large ones.
- **Covers without CoverBrowser:** covers are read from the EPUB itself (EPUB 2 and 3), rendered by KOReader and kept in a small memory cache.
- **Previews:** previews now use real covers, extracted from the sample EPUBs, plus a colour variant.
- **Design explainers:** `tools/specimen.lua` draws the type scale, text at real size and margins to scale. `SERENO_PREVIEW_GRID=1` draws the design grid over the home screen.
- **Home screen:**
  - Contextual home screen: continue reading, finished, start, empty.
  - Designed from physical sizes, with a modular type scale, millimetre margins and grid, and e-ink-safe greys.
  - Opens at start-up or after closing a book (both optional), or from a gesture.
- **Book metrics:**
  - Computed without opening books: Sereno's print-model page count, plus APNX, Adobe and characters-per-page estimates, a downloaded printed count (Open Library), words, reading time, and language-specific readability (English, Spanish, German).
  - "Pages & readability" in the file long-press dialog and on hold over a book on the home screen.
  - Count all books in a folder, with progress and cancel.
- **Settings:** page count method and reading speed.
- **Languages:** Spanish translation.
- **Development:** CI running all specs on LuaJIT, and layout previews for several devices.

### Changed
- **Readable reader margins:** Paperback now has 8 mm side margins (was 6 mm) and a 1.5 line height (was about 1.3), Airy 14 mm. The line height now follows crengine's real line height (1.36 em for 100 % in Noto Serif), and the line-length cap uses Noto Serif's measured width (0.52 em a character).
- **Base text size on 10" screens:** 13.5 pt (was 12.5 pt).
- **Reader pages in `tools/korender`:** now set like crengine sets them (hyphenation patterns, condensable spaces, indents, chapter openings, status bar), in device frames.
- Interface margins are rounded up, so they are never under 6 mm.

### Fixed
- **Shelf captions:** a word wider than its caption, such as "Frankenstein" on a 6" screen, is now shortened with an ellipsis. KOReader's text box used to break it mid-word ("Frankenstei / n"). Found by rendering with KOReader's real widgets.
- Strings are now English, with a plugin-local translation layer.
- The Sereno menu is reorganised: Home screen, Page counts, Tiered menus, Refresh budget.

## 0.1.0

### Added
- Tiered menus (Reading, Everyday, Everything), built on KOReader's menu order file.
- E-ink refresh coordinator.
