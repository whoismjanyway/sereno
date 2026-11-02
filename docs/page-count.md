# How Sereno counts pages

## The problem

An e-book has no pages. Each reader draws them, and the number depends on the screen, the font and the margins.

- **KOReader's page numbers** follow the current layout. They are exact for *your* screen right now, but useless for comparing books or talking about "page 120", and they change with every font tweak.
- **KOReader's synthetic page map** cuts the text every *N* characters (1500 by default, see [koreader#9020](https://github.com/koreader/koreader/issues/9020)). It is stable, but crengine builds it only after the book is opened and rendered, so a library list or a home screen can't show it for books you haven't opened.
- **Publisher page lists** (EPUB `page-list`) are perfect when present, but most books don't have one.

Calibre's [Count Pages](https://github.com/kiwidude68/calibre_plugins/wiki/Count-Pages) plugin solved the library-wide part:
- **Estimating** a count from the file (APNX "accurate", Adobe, Calibre viewer, or custom characters per page), or **downloading** one from Goodreads.
- **Storing** it in custom columns, together with word counts and readability scores.

Sereno brings that approach into KOReader itself and adds a better estimator.

## The print model

Sereno *typesets* each content document on a reference printed page instead of dividing characters by a constant.

| Parameter | Value | Why |
|---|---|---|
| Characters per line | 64 | Typical trade paperback measure (spaces included) |
| Lines per page | 32 | Typical trade paperback |
| Paragraph indent | 3 characters | First-line indent, not used after a `<br>` |
| Headings | 40 characters per line, 1.5× line height, plus 2 blank lines | Display sizes |
| Chapter openings | 8 extra lines when a document starts with a heading | Chapters start lower on the page |
| Images | 11 lines (about a third of a page) | |
| Scene breaks (`<hr>`) | 2 lines | |
| Each spine document | Starts a new page | Chapters start on a fresh page in print |

The text is word-wrapped greedily. CJK text, which has no spaces, is filled by columns, with wide characters counting double. Words longer than a line are broken.

**Why typesetting beats a character count.** Two books with the same number of characters can differ a lot in print.
- A novel full of short dialogue lines leaves the end of most lines empty.
- Verse, letters and lists do the same.
- Short chapters waste the rest of their last page.

A characters-per-page count misses all of this, while the print model sees it. That is why *Alice's Adventures in Wonderland*, with its short chapters, verse and 42 illustrations, gets 125 print-model pages against 101 by characters.

### Calibration

The parameters were chosen to match a typical trade paperback, then checked against books with a well-known paperback edition. They are built from [Standard Ebooks](https://standardebooks.org) sources, which are clean, consistent EPUBs:

| Book | Print model | Reference |
|---|---|---|
| The Great Gatsby | 179 | Scribner paperback (2004): 180 pages |

Paper editions vary widely: *Pride and Prejudice* runs from about 280 to 480 pages depending on publisher and type size. So the honest claim is "close to a typical paperback", not "matches your edition". When you want your edition's count, use **Download printed page count**.

CI rebuilds *The Great Gatsby* from Standard Ebooks on every push and checks the print model stays within 8% of 180 (`SERENO_BOOKS` in `spec/metrics_spec.lua`). More reference books are welcome; see [CONTRIBUTING.md](../CONTRIBUTING.md).

## The other estimators

They are kept so you can compare, and so Calibre users get the numbers they already know.

- **apnx**: Count Pages' "APNX accurate" algorithm.
  - Scans the raw HTML: a line at every `<p>` (or `<div>`, whichever is more common), plus a line for every 70 characters inside paragraphs. The counter carries over between paragraphs, as in the original.
  - 31 lines per page.
  - Backstop: plain characters / 2400 + 1, whichever is larger.
- **adobe**: Adobe Digital Editions' rule, one page per started 1024 bytes of *compressed* data in each spine file. Sereno reads compressed sizes straight from the ZIP central directory, in pure Lua, because KOReader's archiver does not expose them.
- **chars**: characters / 1500, the same density as KOReader's synthetic page map, so both numbers line up.
- **downloaded**: [Open Library](https://openlibrary.org/developers/api).
  - **With an ISBN:** that edition's `number_of_pages`.
  - **Otherwise:** a search by title and author's surname, taking `number_of_pages_median` of the work with the most editions.

Comics (CBZ) count one page per image. PDF and DjVu use their real page count.

## Words and readability

- **Words:** runs of letters and digits, with apostrophes and hyphens inside words kept. Each CJK ideograph counts as one word, like Calibre's ICU counter.
- **Readability:** computed on the whole book up to 60,000 words, and on evenly spaced paragraphs beyond that. Each language gets the formula made for it:

| Language | Formula | Scale shown |
|---|---|---|
| English | Flesch Reading Ease, plus Flesch–Kincaid grade and Gunning Fog | Flesch bands |
| Spanish | Szigriszt-Pazos perspicuity | INFLESZ bands (Barrio-Cantalejo et al., 2008) |
| German | Amstad's adaptation of Flesch | Flesch bands |
| Others | Flesch Reading Ease, flagged "approximate" | Flesch bands |

Flesch's original formula over-rates Spanish, whose words have more syllables; that is why Spanish uses its own formula.

Syllables are counted by rules per language, with no dictionaries, because they would be too big for an e-reader:
- **English:** vowel groups, minus silent endings.
- **Spanish:** vowel nuclei with diphthong and hiatus rules.
- **German:** vowel groups, with the usual diphthongs counted once.

## Storage

Results live in `settings/sereno/metrics.lua`, keyed by file path, with the file's size and modification time and the analyser version.
- **Replaced files:** a replaced file is counted again.
- **Algorithm changes:** an improved algorithm (a higher `Analyzer.VERSION`) refreshes old records.
- **No side effects on your books:** books are never opened by KOReader for this, and no `.sdr` folders are created for books you haven't read.

## Performance

On a desktop with LuaJIT a 120,000-word novel takes about 0.2 s. E-readers are roughly 5–15 times slower, so expect about 1–3 s per book. That is why:
- **Home screen:** books it shows are counted in the background, one per tick, after the screen is drawn.
- **Whole folders:** counting a folder shows progress and can be cancelled with a tap.
- **Already counted:** books that were counted before are skipped.
