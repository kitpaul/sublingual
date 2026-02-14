# SUB-1: Fix fd leak — Too many open files after 3600+ directories

- **Type:** bug
- **Priority:** high
- **Status:** closed
- **Labels:** bug, fix, bash-3.2
- **Created:** 2026-02-14
- **Closed:** 2026-02-14

## Description

Running `--fix-names` across 7000+ directories caused `Too many open files` errors starting around directory 3600. Root cause: `< <(find ...)` process substitutions and `$(find ... -print -quit)` command substitutions in hot-path functions leaked file descriptors that bash 3.2 did not clean up.

## Fix

- Replaced process substitutions in `fix_subtitle_names()` with glob-based `for _f in "$dir"/*` loops
- Created `find_nfo()` and `find_video()` helper functions using globs instead of `$(find ...)`
- Replaced `find | grep` video detection in scanning loops with glob + case matching
- Added `shopt -s nocasematch` / `nocaseglob` for case-insensitive extension matching (bash 3.2 compatible)
- Replaced `find -newer` with `stat -f%m` timestamp comparison in `rename_subtitles()`

## Verification

- Sequential thinking analysis confirmed the approach
- Codex (GPT-5) code review validated: fd leak fix is correct, nocasematch is bash 3.2 compatible, remaining `< <(find ...)` only run once per root (acceptable)
- Both reviewers flagged the case-sensitivity regression (fixed with nocasematch/nocaseglob)
