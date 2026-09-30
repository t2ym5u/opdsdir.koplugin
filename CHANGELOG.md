# Changelog

All notable changes to this project will be documented in this file.

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
