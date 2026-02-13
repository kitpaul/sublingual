# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sublingual is a single-file Bash script (`sublingual.sh`, ~2300 lines) that batch-downloads multi-language subtitles for movie collections on macOS. It queries OMDb for metadata, caches results in NFO files, and downloads subtitles from Subliminal and OpenSubtitles.

## Running and Testing

```bash
# Check dependencies and version
./sublingual.sh --version

# Dry-run (no changes, safe for testing)
./sublingual.sh --folder "/path/to/Movies" --language EN --dry-run

# Debug mode (verbose logging)
./sublingual.sh --folder "/path/to/Movies" --language EN --debug

# Normal run
./sublingual.sh --folder "/path/to/Movies" --language EN,ES,FR

# Survey mode (continuous monitoring loop)
./sublingual.sh --folder "/path/to/Movies" --language EN --survey
```

There are no automated tests. Validation is done via `--dry-run` and `--debug` flags.

## Architecture

The script is a single Bash file with these major sections:

1. **Constants & Config** (lines 1-46): Version, API limits, file paths (`~/.sublingual_api_state`, `~/.sublingual_imdb_map`, `~/.sublingual_survey_state`), configuration defaults
2. **Utilities** (lines 48-160): Logging (`debug/info/warn/error/fatal`), URL encoding, temp files, input validation
3. **API Budget** (lines 349-415): Daily OMDb call tracking persisted to `~/.sublingual_api_state`, hard limit at 490/500 calls
4. **IMDb Lookup Chain** (lines 546-1180): Five-strategy fallback to resolve movie -> IMDb ID:
   - `get_imdb_from_dirname()` — parse `[tt1234567]` from folder name
   - `get_imdb_from_nfo()` — read cached NFO XML
   - `get_imdb_from_mapping()` — check `~/.sublingual_imdb_map`
   - `get_imdb_from_omdb()` — query OMDb API (costs budget)
   - `get_imdb_from_ddgr()` — DuckDuckGo web search fallback
5. **NFO Cache** (lines 643-830): `validate_cache_data()` and `write_nfo_cache()` — XML metadata files compatible with Kodi/Plex/Jellyfin
6. **Subtitle Download** (lines 1252-1427): `run_subliminal()`, `run_subdownloader()`, `download_opensubtitles()` — multiple download backends
7. **Movie Processing** (lines 1428-1842): `process_movie()` orchestrates the full pipeline per movie directory
8. **Main Loop** (lines 2002-2250): `main()` scans directories, dispatches processing, handles survey mode cycling

## Key Constraints

- **Bash 3.2 compatible**: No associative arrays, no `readarray`, no `${var,,}`. This is intentional for macOS stock bash.
- **OMDb API budget**: Free tier = 1000/day, script stops at 490. The budget system in `load_api_state`/`save_api_state`/`check_api_limit` is critical — never bypass it.
- **`validate_imdb_id()`** (line 1000): Uses OMDb `i=` parameter to verify IMDb IDs are real. Always costs one API call.
- **NFO files use `plot=full`**: OMDb queries request full-length plots for richer metadata.

## Versioning

The repo preserves historical versions as `sublingual-macos-v.01.sh` through `v.18.sh`. The current working version is always `sublingual.sh`. When creating new versions, follow the existing `v.XX` naming pattern.

## External Dependencies

- **Required**: `curl`, `unzip`, `file`
- **Optional**: `subliminal` (pip), `subdownloader`, `ddgr` (brew)
- **API**: OMDb key via `$OMDB_API_KEY` env var or `--omdb-key` flag
