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
    ├── reader/layout.lua      ✱ reading layouts in pt/mm → KOReader's font size and margins
    ├── home/
    │   ├── context.lua        ✱ what to show: reading / finished / start / empty
    │   ├── presenter.lua      ✱ the words on screen
    │   ├── layout.lua         ✱ positioned nodes, vertical budget, wrap
    │   └── homescreen.lua     KOReader widget: paints nodes, taps, clock
    └── library.lua            KOReader data sources: history, book state, covers, new books
```

**✱ = pure Lua.** These modules don't depend on KOReader. Everything they need (file system, UIManager, HTTP, clock, screen) is passed in, so they run under plain LuaJIT in `spec/` and in `tools/`. The KOReader-facing modules are kept thin.

## KOReader extension points used

| What | How |
|---|---|
| Hide menu items | `settings/{reader,filemanager}_menu_order.lua` with `KOMenu:disabled`, KOReader's own per-user override, read on every menu build. Regenerated at start from KOReader's current defaults. |
| Own menu | `ui.menu:registerToMainMenu` |
| Long-press entry | `FileManager:addFileDialogButtons` |
| Gestures | `Dispatcher:registerAction` (`sereno_show_home`, `sereno_cycle_tier`, …) |
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

With `KORENDER_READER=1` it also sets sample reader pages with KOReader's text renderer to compare reading layouts. crengine itself is not built, so these pages are an approximation of the reader, not a screenshot of it.

## Tests

`luajit spec/run.lua` runs these specs:

| Spec | What it checks |
|---|---|
| `menu_spec` | Tier engine and order files, plus KOReader's real menus when `KOREADER_DIR` is set |
| `refresh_spec` | Grouping, flash policy, shared timer, pause/resume |
| `metrics_spec` | ZIP, HTML, EPUB, estimators, readability, cache and Open Library, plus real books when `SERENO_BOOKS` is set |
| `theme_spec` | Physical sizing |
| `home_spec` | Context, wording, and the layout on 7 screen sizes × 4 states |
| `reader_spec` | Reading layouts: physical sizes, line-length cap, valid KOReader values |
| `smoke_spec` | Loads `main.lua` against stubs of KOReader modules (`spec/koreader_stubs.lua`), walks every menu, shows the home screen, taps every target, opens the metrics dialog, counts a folder |
| `l10n_spec` | Translations are complete and keep their placeholders |
