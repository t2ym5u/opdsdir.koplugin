# opdsdir — OPDS per-catalog download directory & encryption

> ⚠️ **Not stable — tested on Kobo only.** This plugin monkey-patches KOReader's internal OPDS browser. It may break if KOReader updates the functions it overrides. Use at your own risk and check the [Known limitations](#known-limitations) section before installing.

---

## What it does

KOReader's built-in OPDS browser uses a single global download folder for all catalogs. **opdsdir** lets you assign a dedicated folder and an optional AES-256 encryption key **per catalog**, so you can keep articles and books separate, and store encrypted EPUBs on a public server.

| Feature | Description |
|---|---|
| 📁 Per-catalog folder | Each catalog can download to its own directory |
| 🔑 Per-catalog encryption | EPUBs and catalogs encrypted with AES-256-CBC |
| 🔓 Transparent decryption | Decryption happens automatically after download |

---

## Installation

1. Download [`opdsdir.zip`](https://github.com/t2ym5u/koreader-plugins/raw/master/dist/opdsdir.zip)
2. Extract into your KOReader `plugins/` directory — you should get `plugins/opdsdir.koplugin/`
3. Restart KOReader

---

## Usage

### Set a download folder

Long-press a catalog in the OPDS browser → **Set download directory** → choose a folder.

Downloads from that catalog will be saved there instead of the global default.
Long-press that same button to clear the folder and fall back to KOReader's
global one.

The folder and the key survive an **Edit** of the catalog, and a sync uses each
catalog's own folder and key rather than those of the last one opened.

### Set an encryption key

Long-press a catalog → **Set encryption key** → enter the passphrase.

The passphrase must match the one used to encrypt files on the server side (e.g. the `EPUB_ENCRYPT_KEY` secret in [reading-pipeline](https://github.com/t2ym5u/reading-pipeline)).

Once set:
- Encrypted catalogs (`catalog.xml.enc`) are decrypted in memory before display
- Downloaded EPUBs are decrypted on-device before opening

> The key is stored in KOReader's OPDS settings file (`opds.lua`), which is not encrypted. Anyone with physical access to the device can read it.

---

## How it works

opdsdir monkey-patches six functions of `OPDSBrowser`, once per session:

| Function patched | What changes |
|---|---|
| `getCurrentDownloadDir` | Returns the per-catalog folder if set |
| `onMenuSelect` | Captures folder and key when entering a catalog |
| `fetchFeed` | Decrypts `*.enc` catalog XML before parsing |
| `downloadFile` | Decrypts downloaded files before handing them to KOReader |
| `fillPendingSyncs` | Applies the right folder and key to each synced catalog |
| `editCatalogFromInput` | Carries folder and key across an edit of the catalog |
| `onMenuHold` | Adds two new buttons to the long-press context menu |

Decryption itself lives in `decrypt.lua`. It uses libcrypto directly through
LuaJIT's FFI — KOReader already bundles it and exposes it in
`base/ffi/crypto.lua` — so nothing is written to disk and no shell command is
run. The `openssl` binary is a fallback, used only if libcrypto cannot be
loaded. If neither is available the plugin says so rather than failing
silently.

---

## Known limitations

- **Kobo only** — other devices are untested
- **`onMenuHold` is replaced**, not wrapped — if KOReader adds buttons to that function in a future update, they will not appear until this plugin is updated
- The encryption key is stored in plaintext on the device (in `opds.lua`)
- On the `openssl` fallback only, the key is also written to a temporary file for the duration of each decryption; the libcrypto path keeps it in memory
- Git history of the server repo may contain unencrypted files from before encryption was enabled

---

## Compatibility

| KOReader version | Status |
|---|---|
| 2024.x / 2025.x (Kobo) | ✅ Tested |
| Other versions | ❓ Unknown |

---

## Related

- [reading-pipeline](https://github.com/t2ym5u/reading-pipeline) — the server side: GitHub Issues → EPUB → encrypted OPDS catalog
