# Contributing

Thanks for helping. The most useful contributions right now are listed below.

## Report how it behaves on your device

Open an issue with:
- **Your setup:** the device model, firmware, KOReader version and Sereno version.
- **What you saw:** a screenshot (KOReader can take one: tap the top two corners at the same time).
- **For errors:** the relevant lines of `koreader/crash.log`.

## Add a reference book for page counts

If you own a paperback of a public-domain book available from [Standard Ebooks](https://standardebooks.org), add its page count to the `expected` table in `spec/metrics_spec.lua`. Include the edition (publisher, year, ISBN) in the pull request.

## Translate

1. Copy `sereno.koplugin/sereno/l10n/es.lua` to your language code (for example `fr.lua`).
2. Translate the values. Keep `%1`, `%2`… as they are.
3. Add the code to `available` in `sereno/l10n.lua` and to `LANGS` in `spec/l10n_spec.lua`.
4. Run `luajit tools/msgids.lua` to see every source string, and `luajit spec/run.lua` to check nothing is missing.

## Code

- **Pure modules:** keep pure modules pure (see [docs/architecture.md](docs/architecture.md)) and inject anything that touches KOReader.
- **Tests:** add a spec for every change. `luajit spec/run.lua` must pass, and CI runs it on every push.
- **Lua version:** target LuaJIT and Lua 5.1 syntax. No `//`, no `utf8` library, no integer-only formatting of floats.
- **No patching:** don't patch KOReader internals. If you need an extension point that doesn't exist, open an issue: it belongs in the Shell API proposal.
- **Plugin requires:** every `require("sereno/…")` must happen at load time (KOReader only puts the plugin folder on `package.path` while `main.lua` loads).
