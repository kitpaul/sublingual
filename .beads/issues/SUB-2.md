# SUB-2: Add --clean-names to strip bracket tags from folder names

- **Type:** feature
- **Priority:** medium
- **Status:** closed
- **Labels:** feature, naming
- **Created:** 2026-02-14
- **Closed:** 2026-02-14

## Description

YTS-downloaded movie folders have bracket tags like `[1080p] [BluRay] [5.1] [YTS.MX]` that need to be stripped before importing into a media server. Some folders also have the year in brackets `[2021]` instead of parentheses `(2021)`.

## Implementation

New `--clean-names` flag and `clean_folder_name()` function with three regex patterns:
1. `Title (Year) [tags...]` → strip bracket tags, keep `Title (Year)`
2. `Title [Year]` → convert to `Title (Year)`
3. `Title [Year] [tags...]` → convert year, strip tags

Skips ambiguous names (no recognizable year pattern). Collision detection. Dry-run support. No API key needed.

## Testing

- Dry-run on `/Volumes/Media/Movies` (30 dirs): 21 renamed, 7 collisions caught, 2 correctly skipped
- Dry-run on `/Volumes/Extreme SSD/Vid` (442 dirs): 440 renamed, 0 collisions, 2 correctly skipped (`Hamlet 2000 [1080p]`, `Scanners.1981...`)
- Dry-run on `/Volumes/Extreme SSD/Vid/_To-clean-up` (360 dirs): all processed correctly
- Edge cases handled: `Bombshell [2019]]` (double bracket), `L'argent [1983]` (apostrophe), `8½ (1963) [1080p]` (unicode)

## Verification

- Sequential thinking: 8-step analysis, confirmed regex correctness and edge cases
- Codex review: patterns sensible, anchors/guards correct, pre-collection prevents traversal breakage
