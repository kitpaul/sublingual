# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Sublingual is a single-file Bash script (`sublingual.sh`, ~2600 lines) that batch-downloads multi-language subtitles for movie collections on macOS. It queries OMDb for metadata, caches results in NFO files, and downloads subtitles from Subliminal and OpenSubtitles. It supports scanning multiple drives and automatically repairs subtitle filenames to the universal `VideoBase.lang.ext` convention.

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

# Multi-drive run (comma-separated paths)
./sublingual.sh --folder "/drive1/Movies,/drive2/Movies" --language EN,RO,FR,DE

# Survey mode (continuous monitoring loop)
./sublingual.sh --folder "/path/to/Movies" --language EN --survey

# Fix subtitle filenames only (no API key needed)
./sublingual.sh --fix-names --folder "/path/to/Movies"

# Fix names with dry-run preview
./sublingual.sh --fix-names --dry-run --folder "/path/to/Movies"
```

There are no automated tests. Validation is done via `--dry-run` and `--debug` flags.

## Architecture

The script is a single Bash file with these major sections:

1. **Constants & Config** (top): Version, API limits, file paths (`~/.sublingual_api_state`, `~/.sublingual_imdb_map`, `~/.sublingual_survey_state`), configuration defaults
2. **Utilities**: Logging (`debug/info/warn/error/fatal`), URL encoding, `json_extract()`, `xml_escape()`, temp files, input validation, `require_arg()`
3. **API Budget**: Daily OMDb call tracking persisted to `~/.sublingual_api_state`, hard limit at 490/500 calls. All date comparisons use UTC (`date -u`).
4. **IMDb Lookup Chain**: Five-strategy fallback to resolve movie -> IMDb ID:
   - `get_imdb_from_dirname()` — parse `[tt1234567]` from folder name
   - `get_imdb_from_nfo()` — read cached NFO XML
   - `get_imdb_from_mapping()` — check `~/.sublingual_imdb_map` (uses `grep -iF` to avoid regex injection)
   - `get_imdb_from_omdb()` — query OMDb API (costs budget)
   - `get_imdb_from_ddgr()` — DuckDuckGo web search fallback
5. **NFO Cache**: `validate_cache_data()` and `write_nfo_cache()` — XML metadata files compatible with Kodi/Plex/Jellyfin. All user data passed through `xml_escape()`.
6. **Subtitle Download**: `run_subliminal()`, `run_subdownloader()`, `download_opensubtitles()` — multiple download backends. OpenSubtitles uses HTML scraping of opensubtitles.org (not the REST API).
7. **Subtitle Naming**: `rename_subtitles()` derives base name from actual video file. `fix_subtitle_names()` repairs existing misnamed files. Pattern: `VideoBase.lang.ext`, `VideoBase.lang2.ext` for duplicates.
8. **Movie Processing**: `process_movie()` orchestrates the full pipeline per movie directory
9. **Main Loop**: `main()` parses comma-separated `--folder` paths into `MOVIE_DIRS[]`, runs `fix_subtitle_names` as pre-step, then scans and processes. Handles survey mode cycling.

## Key Constraints

- **Bash 3.2 compatible**: No associative arrays, no `readarray`, no `${var,,}`, no `${!array[@]}`. This is intentional for macOS stock bash.
- **Glob-safe string comparisons**: Filenames with brackets (e.g., `[1080p]`) are treated as glob patterns by `==` and `${var#pattern}`. Use substring extraction (`${var:0:N}`) instead.
- **OMDb API budget**: Free tier = 1000/day, script stops at 490. The budget system in `load_api_state`/`save_api_state`/`check_api_limit` is critical — never bypass it. Midnight reset uses UTC.
- **`validate_imdb_id()`**: Uses OMDb `i=` parameter to verify IMDb IDs are real. Always costs one API call.
- **NFO files use `plot=full`**: OMDb queries request full-length plots for richer metadata.
- **Subtitle naming convention**: `VideoBase.lang.ext` is the universal standard recognized by Plex, Jellyfin, Kodi, and Synology Video Station. The video base name must match exactly (minus extension).
- **Video file selection**: When multiple video files exist (e.g., 1080p + 4K), the script scores each by how many existing subtitles reference its base name, falls back to resolution-tag matching, then largest file.

## Versioning

Historical versions are kept on the development machine as `sublingual-macos-v.01.sh` through `v.20.sh`. The current working version is always `sublingual.sh`. Current version: v1.1.0.

## External Dependencies

- **Required**: `curl`, `unzip`, `file`
- **Optional**: `subliminal` (pip), `subdownloader`, `ddgr` (brew)
- **API**: OMDb key via `$OMDB_API_KEY` env var or `--omdb-key` flag
