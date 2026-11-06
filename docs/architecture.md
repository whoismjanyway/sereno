# Architecture

```
sereno.koplugin/
├── _meta.lua, main.lua        plugin entry: lifecycle, menus, dispatcher actions, glue
└── sereno/
    ├── l10n.lua, l10n/es.lua  translations (English source strings)
    ├── menu/                  tiered menus
    │   ├── tiers.lua          ✱ filters KOReader's menu order by level
    │   ├── tier_defaults.lua  ✱ default level of every KOReader menu id
    │   ├── serialize.lua      ✱ writes the order file
    │   └── orderfile.lua      ✱ adopts/restores the user's own order file
    ├── eink/refresh.lua       ✱ refresh coordinator (grouping, shared timer, flash policy)
    ├── metrics/               book metrics
    │   ├── zip.lua            ✱ ZIP central directory reader (compressed sizes)
    │   ├── text.lua           ✱ UTF-8, columns, word counting
    │   ├── html.lua           ✱ XHTML → paragraphs, headings, images, breaks
    │   ├── epub.lua           ✱ container.xml, OPF metadata and spine
    │   ├── pages.lua          ✱ print model, APNX, Adobe, chars estimators
    │   ├── readability.lua    ✱ syllables (en/es/de), Flesch, Szigriszt-Pazos, Amstad, FK, Fog
    │   ├── analyzer.lua       ✱ one book → one metrics record
    │   ├── cache.lua          ✱ library-wide store, validated by size/mtime/version
    │   ├── openlibrary.lua    ✱ printed page count lookup (HTTP/JSON injected)
    │   ├── service.lua        KOReader glue: libarchive, documents, Trapper, LuaSocket
    │   └── dialog.lua         "Pages & readability" dialog
    ├── ui/theme.lua           ✱ design system from physical units
    ├── ui/painter.lua         draws nodes with KOReader's widgets (every Sereno screen)
    ├── ui/overlay.lua         window for sheets over the screen (quick controls, reader bars)
    ├── shell/browse.lua       ✱ Library / Reading / Collections / Search models
    ├── shell/layout.lua       ✱ their grid of covers, title row, pager
    ├── controls/layout.lua    ✱ quick controls sheet
    ├── reader/chrome.lua      ✱ the reader's top and bottom bars
    ├── sleep/layout.lua       ✱ Sereno's sleep screen image
    ├── reader/folio.lua       the book page: running head and page number (a ReaderView view module)
    ├── stats/stats.lua        ✱ reading statistics: streak, averages, time left
    ├── stats/source.lua       reads KOReader's statistics.sqlite3 (read-only)
    ├── transfer/http.lua      ✱ request parsing, safe file names, the upload page
    ├── transfer/server.lua    ✱ non-blocking upload server (LuaSocket passed in), polled by a timer
    ├── transfer/layout.lua    ✱ the "Send books over Wi-Fi" screen
    ├── reader/
    │   ├── layout.lua         ✱ the page in pt/mm (size, spacing, margins, alignment, paragraphs) → KOReader settings and style tweaks
    │   ├── panel.lua          ✱ the Text panel (font, size, page) as positioned nodes, and its miniature pages
    │   └── panelwidget.lua    KOReader widget: bottom sheet, taps
    ├── home/
    │   ├── context.lua        ✱ what to show: reading / finished / start / empty
    │   ├── presenter.lua      ✱ the words on screen
    │   ├── layout.lua         ✱ positioned nodes, vertical budget, wrap
    │   └── homescreen.lua     KOReader widget: paints nodes, taps, clock
    ├── archive.lua            EPUB (ZIP) reading: KOReader's libarchive, iterated first; the device's unzip as fallback
    └── library.lua            KOReader data sources: history, book state, covers, new books
```

**✱ = pure Lua.** These modules don't depend on KOReader. Everything they need (file system, UIManager, HTTP, clock, screen) is passed in, so they run under plain LuaJIT in `spec/` and in `tools/`. The KOReader-facing modules are kept thin.

## KOReader extension points used

| What | How |
|---|---|
| Hide menu items | `settings/{reader,filemanager}_menu_order.lua` with `KOMenu:disabled`, KOReader's own per-user override, read on every menu build. Regenerated at start from KOReader's current defaults. |
| Own menu | `ui.menu:registerToMainMenu` |
| Long-press entry | `FileManager:addFileDialogButtons` |
| Gestures | `Dispatcher:registerAction` (`sereno_show_home`, `sereno_page_panel`, `sereno_cycle_tier`, …) |
| Reader bars and quick controls | `ui:registerTouchZones` with `overrides` of `readermenu_tap`, `readerconfigmenu_tap`, `readermenu_swipe` |
| Quick control actions | `UIManager:broadcastEvent` of KOReader's events (`ToggleWifi`, `ToggleNightMode`, `IterateRotation`, `Restart`, `RequestSuspend`), `powerd:setIntensity` / `setWarmth` |
| Reader navigation | `GotoPage`, `ReaderToc` chapters, `ReaderLink` location stack, `ReaderPageMap` labels |
| Collections | `ReadCollection` |
| Book page | `ReaderView:registerViewModule("sereno_folio", …)`; `ReaderFooter:applyFooterMode` to hide and give back the status bar |
| Reading statistics | `settings/statistics.sqlite3` through `lua-ljsqlite3` (read-only) |
| Import | The calibre plugin (`StartWirelessConnection`) and the OPDS plugin (`onShowOPDSCatalog`) |
| Send over Wi-Fi | LuaSocket (`socket.bind`, non-blocking `accept`/`receive`/`send`) polled with `UIManager:scheduleIn`; `NetworkMgr:runWhenConnected`; `UIManager:preventStandby` / `allowStandby`; on Kindle, `iptables` rules added and removed as the SSH plugin does |
| By cable | `RequestUSBMS` when `Device:canToggleMassStorage()` (Kobo, Cervantes); on Kindle, KOReader's `Exit` so Amazon's USB drive mode can start |
| Unified settings | A `TouchMenu` with Sereno's tab followed by `ui.menu.tab_item_table` (KOReader's own tabs) |
| Settings tab icon | `sereno.logo.svg` copied into KOReader's user icons folder (`<data>/icons`) |
| Sleep screen | `screensaver_type = "random_image"` with `screensaver_dir` = Sereno's folder (previous values kept and restored); `ui/elements/screensaver_menu` for KOReader's own options; `onSuspend` / `onResume` |
| Reader menu entry | `menu_items.sereno_page` with `sorting_hint = "typeset"`, next to KOReader's own font settings |
| Page layout | `SetFontSize`, `SetLineSpace`, `SetPageMargins` events; `ReaderStyleTweak.global_tweaks` and `updateCssText`; `copt_*` and `style_tweaks` in `G_reader_settings` |
| Home screen | A regular `InputContainer` shown with `UIManager:show` |
| Covers and metadata | `package.loaded.bookinfomanager` (CoverBrowser's cache) when present |
| Reading state | `ReadHistory.hist`, `BookList.getBookInfo`, `DocSettings` |
| EPUB contents | `ffi/archiver` (libarchive), plus Sereno's own ZIP index for compressed sizes |
| Networking | `NetworkMgr:runWhenOnline`, `socket.http` with `socketutil` timeouts |

Nothing is monkey-patched. Sereno can therefore sit next to other plugins: its home screen is just another window, and its menu file can be turned off and restored at any time.

## Loading rule

KOReader only adds a plugin's folder to `package.path` while `main.lua` is being loaded. Every `require("sereno/...")` therefore has to run at load time, either directly in `main.lua` or in a module `main.lua` requires. KOReader's own modules can be required lazily.

## Rendering with KOReader's real widgets

`tools/korender` assembles a small KOReader runtime from:
- KOReader's `frontend/`
- koreader-base's `ffi/`
- koreader-fonts
- luafilesystem, built as KOReader's lfs module
- the system's FreeType

It then draws Sereno's HomeScreen with KOReader's real Blitbuffer, Font, TextWidget, TextBoxWidget, IconWidget and ImageWidget code, and writes PNGs. The only C pieces it replaces are image decoding (nanosvg, turbojpeg, MuPDF scaling), which ImageMagick and Lua stand in for, and utf8proc case folding. CI runs it on every push, so a change in KOReader's widget API that breaks Sereno's drawing shows up there.

With `KORENDER_READER=1` it also sets the opening page of a book, KOReader's default layout next to Sereno's, the three pages, and the Text panel over the page (the real `PanelWidget`). `tools/korender/bookpage.lua` sets those pages the way crengine does: crengine's hyphenation patterns (Liang's algorithm), greedy line filling with spaces that may condense to 75 %, first-line indents, the font's own line height. crengine itself is not built, so these pages are a close approximation of the reader, not a screenshot of it. `tools/korender/compose.py` puts them in device frames for the README.

## Tests

`luajit spec/run.lua` runs these specs:

| Spec | What it checks |
|---|---|
| `menu_spec` | Tier engine and order files, plus KOReader's real menus when `KOREADER_DIR` is set |
| `refresh_spec` | Grouping, flash policy, shared timer, pause/resume |
| `metrics_spec` | ZIP, HTML, EPUB, estimators, readability, cache and Open Library, plus real books when `SERENO_BOOKS` is set |
| `theme_spec` | Physical sizing |
| `home_spec` | Context, wording, and the layout on 7 screen sizes × 4 states |
| `reader_spec` | Reading layouts: physical sizes, margins never under 5 mm, line-length cap, independent axes, style tweak ids that exist in KOReader |
| `shell_spec` | Every tab, the quick controls and the reader's bars on 7 screens: nothing leaves the screen or overlaps, touch targets, paging |
| `smoke_spec` | Loads `main.lua` against stubs of KOReader modules (`spec/koreader_stubs.lua`), walks every menu, shows the home screen, taps every target, opens the metrics dialog, counts a folder, drives the Text panel tap by tap, the reader's bars, locations and checks it fits six screens |
| `koreader_api_spec` | Every KOReader function Sereno calls exists in `KOREADER_DIR` (CI: the latest release) |
| `l10n_spec` | Translations are complete and keep their placeholders |
