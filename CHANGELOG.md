# Changelog

## 0.2.0 (unreleased)

### Added
- **Redesigned home screen:**
  - A greeting header.
  - The current book in a card, with its real cover and fact chips.
  - Library tiles (reading, unread, finished).
  - A shelf of covers with progress bars, and *See all*.
  - A tab bar with KOReader's icons.
  - The layout degrades step by step on small screens and adds a second shelf row on large ones.
- **Covers without CoverBrowser:** covers are read from the EPUB itself (EPUB 2 and 3), rendered by KOReader and kept in a small memory cache.
- **Previews:** previews now use real covers, extracted from the sample EPUBs, plus a colour variant.
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
- Strings are now English, with a plugin-local translation layer.
- The Sereno menu is reorganised: Home screen, Page counts, Tiered menus, Refresh budget.

## 0.1.0

### Added
- Tiered menus (Reading, Everyday, Everything), built on KOReader's menu order file.
- E-ink refresh coordinator.
