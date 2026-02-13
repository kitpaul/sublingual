# Sublingual

**Batch movie multi-language subtitle downloader script with NFO caching and survey mode**

Sublingual is an intelligent subtitle downloader Bash script for macOS that automatically finds and downloads subtitles for your movie collection. It supports 34+ languages, caches movie metadata in NFO files, and includes a survey mode for continuous monitoring.

## Features

- **Multi-Language Support**: Download subtitles in 34+ languages including European, Asian, and other major languages
- **Intelligent IMDb Lookup**: Multiple fallback strategies (directory name, NFO files, OMDb API, web search)
- **NFO Caching**: Stores movie metadata to avoid repeated API calls
- **Survey Mode**: Continuously monitors directories for new movies
- **Dual Subtitle Sources**: Uses both Subliminal and OpenSubtitles
- **API Budget Management**: Tracks and limits OMDb API usage (500 calls/day free tier)
- **Subtitle Name Repair**: Automatically fixes subtitle filenames to match the universal `VideoBase.lang.ext` convention (compatible with Plex, Jellyfin, Kodi, Synology Video Station)
- **Multi-Drive Support**: Scan multiple directories or drives in a single command with comma-separated paths
- **Dry-Run Mode**: Test operations without making changes
- **YTS-Optimized**: Special handling for YTS movie folder formats
- **macOS Compatible**: Works with macOS bash 3.2 (no bash 4+ required)

## Requirements

### Required Dependencies

- `curl` - HTTP requests
- `unzip` - Extract subtitle archives
- `file` - File type detection
- **OMDb API Key** - Free API key from [OMDb API](https://www.omdbapi.com/apikey.aspx)

### Optional Dependencies

- `subliminal` - Python-based subtitle downloader (recommended: `pip install subliminal`)
- `subdownloader` - Alternative subtitle source
- `ddgr` - DuckDuckGo search for IMDb lookup fallback

## Installation

1. Clone the repository:
```bash
git clone https://github.com/kitpaul/sublingual.git
cd sublingual
```

2. Make the script executable:
```bash
chmod +x sublingual.sh
```

3. Get your free OMDb API key:
   - Visit https://www.omdbapi.com/apikey.aspx
   - Select the FREE plan (1,000 daily requests)
   - Verify your email
   - Save your API key

4. Configure your API key:
```bash
export OMDB_API_KEY='your-api-key-here'
# Add to ~/.zshrc or ~/.bash_profile to persist
```

## Usage

### Basic Usage

```bash
# Download English subtitles for a single movie
./sublingual.sh --folder "/path/to/movie" --language EN

# Download subtitles in multiple languages
./sublingual.sh --folder "/path/to/movie" --language EN,ES,FR

# Batch process entire movie collection
./sublingual.sh --folder "/path/to/Movies" --language EN

# Scan multiple drives/directories at once
./sublingual.sh --folder "/drive1/Movies,/drive2/Movies,/drive3/Movies" --language EN
```

### Advanced Options

```bash
# Dry-run mode (test without changes)
./sublingual.sh --folder "/path/to/Movies" --language EN --dry-run

# Survey mode (continuous monitoring)
./sublingual.sh --folder "/path/to/Movies" --language EN --survey

# Pass API key via command line
./sublingual.sh --folder "/path/to/Movies" --language EN --omdb-key YOUR_KEY

# Debug mode
./sublingual.sh --folder "/path/to/Movies" --language EN --debug

# Fix subtitle filenames only (no downloads, no API key needed)
./sublingual.sh --fix-names --folder "/path/to/Movies"

# Fix names with dry-run preview
./sublingual.sh --fix-names --dry-run --folder "/path/to/Movies"
```

### Check Dependencies

```bash
# Show version and dependency status
./sublingual.sh --version

# Show help and check dependencies
./sublingual.sh --help

# No arguments also shows status
./sublingual.sh
```

## Supported Languages

### European Languages
EN (English), FR (French), DE (German), ES (Spanish), IT (Italian), PT (Portuguese), NL (Dutch), PL (Polish), RU (Russian), EL (Greek), TR (Turkish), SV (Swedish), NO (Norwegian), DA (Danish), FI (Finnish), CS (Czech), HU (Hungarian), BG (Bulgarian), HR (Croatian), SR (Serbian), SK (Slovak), SL (Slovenian), UK (Ukrainian), RO (Romanian)

### Asian Languages
AR (Arabic), ZH (Chinese), JA (Japanese), KO (Korean), HI (Hindi), TH (Thai), VI (Vietnamese), ID (Indonesian)

### Other Languages
HE (Hebrew), FA (Persian), BN (Bengali)

Language codes are case-insensitive (en, EN, eN all work).

## How It Works

1. **Directory Scanning**: Finds all folders containing video files (.mkv, .mp4, .avi). Supports comma-separated paths for multi-drive setups.
2. **Subtitle Name Repair**: Fixes existing subtitle filenames to match the `VideoBase.lang.ext` pattern before downloading, ensuring accurate duplicate detection.
3. **IMDb Lookup**: Identifies movies using multiple strategies:
   - Parse IMDb ID from directory name (e.g., "Movie (2024) [tt1234567]")
   - Read from existing NFO files
   - Check manual mapping file (`~/.sublingual_imdb_map`)
   - Query OMDb API
   - Web search via ddgr (fallback)
4. **Subtitle Search**: Queries multiple sources:
   - Subliminal (if installed)
   - OpenSubtitles direct API
5. **Metadata Caching**: Stores movie info in NFO files for future use
6. **Smart Download**: Skips movies that already have subtitles

## Configuration Files

Sublingual uses several cache files in your home directory:

- `~/.sublingual_api_state` - Tracks daily OMDb API usage
- `~/.sublingual_imdb_map` - Manual IMDb ID mappings
- `~/.sublingual_survey_state` - Survey mode state tracking

## Examples

### Example 1: Process New Movie
```bash
./sublingual.sh --folder "/Movies/Inception (2010)" --language EN
```

### Example 2: Multi-Language Download
```bash
./sublingual.sh --folder "/Movies/Parasite (2019)" --language EN,KO,ES
```

### Example 3: Survey Mode for Automated Downloads
```bash
./sublingual.sh --folder "/Movies" --language EN --survey
```
This will continuously monitor the Movies folder and automatically download subtitles for any new movies.

### Example 4: Dry-Run Before Processing Large Collection
```bash
./sublingual.sh --folder "/Movies" --language EN,ES --dry-run
```

### Example 5: Fix Subtitle Filenames Across Multiple Drives
```bash
./sublingual.sh --fix-names --folder "/Volumes/Media/Movies,/Volumes/SSD2/Movies,/Volumes/SSD3/Movies"
```
This renames subtitles to the universal `VideoBase.lang.ext` format (e.g., `Movie [1080p].en.srt`, `Movie [1080p].en2.srt` for duplicates). No API key required.

### Example 6: Multi-Drive Survey Mode
```bash
./sublingual.sh --folder "/Volumes/Media/Movies,/Volumes/SSD2/Movies" --language EN,RO,FR,DE --survey
```

## Troubleshooting

### "OMDb API key is not configured"
Apply for a free API key at https://www.omdbapi.com/apikey.aspx and configure it:
```bash
export OMDB_API_KEY='your-key-here'
```

### "API limit reached"
The free OMDb tier allows 1,000 calls per day. Sublingual tracks usage and stops at 490 calls. Reset occurs at midnight UTC.

### Subtitles Not Found
- Verify the movie has the correct IMDb ID
- Try adding manual mapping: `echo "Movie Name|tt1234567" >> ~/.sublingual_imdb_map`
- Check OpenSubtitles.org to confirm subtitle availability

### Missing Dependencies
Run `./sublingual.sh --version` to see which dependencies are missing and install them.

## Project Structure

```
sublingual/
├── sublingual.sh          # Main script
├── CLAUDE.md             # Claude Code project context
├── README.md             # This file
└── LICENSE               # MIT License
```

## API Usage

Sublingual uses the OMDb API for movie metadata lookup:
- **Free tier**: 1,000 requests per day
- **Budget limit**: Script stops at 490 to leave safety margin
- **Rate limiting**: 0.5s delay between requests
- **Caching**: NFO files prevent repeated API calls

## License

MIT License - See [LICENSE](LICENSE) file for details

Copyright (c) 2025 kitpaul

## Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.

## Version

Current version: **v1.1.0**

## Changelog

### v1.1.0 (2026-02-14)
- **Multi-drive support**: `--folder` now accepts comma-separated paths for scanning multiple drives in one run
- **Subtitle name repair** (`--fix-names`): Standalone mode to fix misnamed subtitle files to the universal `VideoBase.lang.ext` convention, compatible with Plex, Jellyfin, Kodi, and Synology Video Station
- **Automatic name repair**: Normal runs and survey cycles now fix subtitle filenames before downloading, improving duplicate detection
- **Smart video matching**: When multiple video files exist (e.g., 1080p and 4K), selects the correct one based on which video existing subtitles reference
- **Bug fixes**: Safer argument parsing, escaped-quote-safe JSON extraction, XML injection prevention in NFO files, UTC-correct midnight reset for API budget, fixed regex injection in IMDb mapping lookup

### v1.0.0 (2025-10-11)
- Initial public release
- Support for 34+ languages (European, Asian, and other major languages)
- OMDb API key validation and management
- Intelligent IMDb lookup with multiple fallback strategies
- NFO caching to minimize API calls
- Survey mode for continuous directory monitoring
- Dual subtitle sources (Subliminal + OpenSubtitles)
- API budget tracking and management
- macOS bash 3.2 compatible

## Links

- **OMDb API**: https://www.omdbapi.com/
- **OpenSubtitles**: https://www.opensubtitles.org/
- **Subliminal**: https://github.com/Diaoul/subliminal

## Support

For issues, questions, or feature requests, please open an issue on GitHub.
