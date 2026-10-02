# Changelog

All notable changes to this project will be documented in this file.

## [1.2.1] - 2026-10-02

### Fixed
- A book that was never encrypted no longer reports a failed decryption. A
  catalog can hold both -- the server encrypts only what it was given a key
  for, and reading-pipeline currently ships at least one plain EPUB -- so with
  a key set on the catalog, every plain download raised "Could not decrypt".
  `Decrypt.file` now returns a status alongside its result: `plaintext` when
  the file carries no `Salted__` header and there is nothing to do,
  `decrypted`, or `failed`. Only `failed` is worth telling the user about.

## [1.2.0] - 2026-10-02

### Changed
- Decryption now runs in-process against libcrypto, which KOReader already
  bundles and exposes through LuaJIT's FFI (`base/ffi/crypto.lua`). The
  openssl binary is kept as a fallback and is used only when libcrypto cannot
  be loaded, since `ffi.loadlib` pins a soname a future KOReader could move.
  `Decrypt.backend()` reports which one is in use.

  This removes, for the libcrypto path: the dependency on an openssl binary
  being present at all, two temporary files per catalog and one per book, a
  fork and exec per file, every shell command and therefore all of the
  quoting -- and the part that actually mattered, **the passphrase being
  written to a world-readable path under /tmp for the duration of each
  decryption**. The key now stays in memory.

  Books are streamed in 64 KB chunks rather than read whole, so peak memory no
  longer tracks the size of the download.

- A device with neither backend now says it cannot decrypt the catalog, rather
  than naming openssl.

### Added
- `test_decrypt_ffi.lua`, which decrypts real `openssl enc -aes-256-cbc
  -pbkdf2` output through the libcrypto backend: block-aligned and unaligned
  plaintexts, a payload spanning several chunks, a wrong key, a missing
  `Salted__` header and a truncated body. It is a plain LuaJIT script rather
  than a busted spec because busted here runs on Lua 5.5, which has no FFI and
  so cannot see this path at all; `test_decrypt_spec.lua` keeps covering the
  same surface through the CLI backend.

## [1.1.0] - 2026-10-02

### Fixed
- `require("i18n")` -> `lrequire("i18n")`. `package.loaded` is keyed by module
  name alone, so the whole device shares one `"i18n"` slot and the first plugin
  loaded wins it. This plugin's own, self-contained `i18n.lua` was therefore
  dead code, and `extend()` merged our strings into the game plugins' shared
  table instead: our `Clear` ("Effacer") overwrote theirs ("Effacer tout"),
  which is already what `Erase` renders, leaving two identical buttons side by
  side in every game.
- Editing a catalog no longer drops its download folder and encryption key.
  `editCatalogFromInput` rebuilds the server entry from the six fields its
  dialog shows and assigns it over the old one, so correcting a typo in a URL
  silently discarded both of ours.
- The patches are applied once instead of on every plugin instance. ReaderUI
  and FileManager each build their own, and rebuild it on every document open
  and close, so the wrappers were stacking on top of each other for the whole
  session.
- Sync uses each catalog's own folder and key. `fillPendingSyncs` sets the
  per-catalog username, password and title itself and knew nothing about ours,
  so "Sync all catalogs" downloaded everything into the folder of whichever
  catalog had been opened last and decrypted it with that one's key.
- A failed decryption now says so. The callback used to fire regardless, so a
  wrong key surfaced as KOReader refusing to open the book, and an encrypted
  catalog simply appeared empty.
- `catalog.xml.enc?v=2` is recognised as encrypted; the query string is
  stripped before the `.enc` test.
- The decryption temporary is a fixed short name in the destination folder
  rather than `<path>.dec`, which could cross the 255-character VFAT limit
  given that KOReader already allows 240-character filenames.

### Added
- `decrypt.lua`, holding the AES-256-CBC implementation behind `available()`,
  `file()` and `data()`, with `test_decrypt_spec.lua` round-tripping real
  `openssl enc -aes-256-cbc -pbkdf2` output through it -- including a wrong
  key, a filename full of shell metacharacters, and a check that no temporary
  is left in the download folder. There was no test of the decryption path at
  all before this.
- A check that an `openssl` binary actually exists, reported to the user
  instead of looking like a bad passphrase.
- Long-press the download-folder button to clear it and fall back to
  KOReader's global folder.

## [1.0.4] - 2026-09-30

### Fixed
- Quote the paths handed to `openssl`, `mv` and `rm`. The download path went
  in between plain single quotes, so a quote inside it closed the quoting and
  the rest ran as shell -- and the path is not ours: KOReader builds the local
  filename from the OPDS entry, which a remote catalogue chooses.

### Added
- `sh.lua`, with a spec that round-trips the quoting through a real shell for
  quotes, backslashes, newlines, substitutions and metacharacters.

## [1.0.3] - 2026-09-30

### Changed
- Now published like every other plugin in the collection: its own repository,
  its own release workflow, and a tagged release per version. It had lived
  inside the monorepo as a plain directory rather than a submodule, so it had
  never been released from a page of its own -- and a bulk
  `cd *.koplugin && git ...` loop over the collection would silently commit to
  the parent repository when it reached this one.

## [1.0.2]

- Per-catalog download folder and AES-256 encryption for the OPDS browser.
