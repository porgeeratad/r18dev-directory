# JAV Link Organizer

`make_jav_links.sh` builds an organized `JAV/` library from a source tree of video files. It scans filenames, extracts the title code, and creates links under `JAV/<PREFIX>/` using normalized names.

The default layout is:

```text
_movie/
├── _index/
└── JAV/
```

Example output:

```text
_movie/JAV/
├── ABP/
│   └── ABP-123.mp4
├── MKBD/
│   ├── MKBD-S130.mp4
│   └── MKBD-S141 - pt2.mp4
└── SSIS/
    └── SSIS-001.mkv
```

## Features

- Recursively scans a source directory for video files
- Creates symbolic links by default
- Supports hard-link mode with `--hardlink`
- Groups output by detected prefix such as `ABP`, `IPX`, `MKBD`, or `SSIS`
- Normalizes filenames to `PREFIX-CODE.ext` or `PREFIX-CODE - ptN.ext`
- Detects multipart files from patterns like `CD2`, `part2`, `pt2`, `141_2`, and `141-2`
- Skips destination files that already exist
- Deduplicates matching titles and keeps the largest source file
- Ignores non-video files and `.DS_Store`
- Supports `--dry-run` preview mode
- Writes a snapshot of destination filenames after each run (for history and tombstoning)
- Supports `--skip-deleted` so user-deleted outputs are not recreated on future runs
- Prints a summary report at the end

## Requirements

- Bash 4+
- Standard Unix tools: `find`, `sort`, `awk`, `sed`, `stat`, `ln`, `mktemp`

On macOS, install a modern Bash if needed because the system default is often too old:

```bash
brew install bash
```

## Installation

Make the script executable:

```bash
chmod +x make_jav_links.sh
```

## Usage

```bash
./make_jav_links.sh [OPTIONS] [SRC] [DST]
```

Options:

- `-n`, `--dry-run`: show planned links without creating them
- `--hardlink`: create hard links instead of symbolic links
- `--symlink`: force symbolic-link mode
- `--src DIR`: set the source directory
- `--dst DIR`: set the destination directory
- `--snapshot FILE`: path to the snapshot file (default: `DST/.jav_snapshot`)
- `--no-snapshot`: do not read or write the snapshot file
- `--skip-deleted`: skip creating links for outputs listed in the snapshot that have since been removed from `DST` (treat them as tombstones so user-intentional deletions are not reintroduced)
- `-h`, `--help`: show help

Examples:

```bash
./make_jav_links.sh
./make_jav_links.sh --dry-run
./make_jav_links.sh --hardlink
./make_jav_links.sh "_movie/_index" "_movie/JAV"
./make_jav_links.sh --src "/path/to/index" --dst "/path/to/JAV"
```

Preview-first examples with local directories:

```bash
# Preview symlink output first
./make_jav_links.sh --dry-run --src "./_index/" --dst "./JAV/"

# Preview hard-link output first
./make_jav_links.sh --dry-run --hardlink --src "./_index/" --dst "./JAV/"

# Create symlinks after reviewing dry-run output
./make_jav_links.sh --src "./_index/" --dst "./JAV/"

# Create hard links after reviewing dry-run output
./make_jav_links.sh --hardlink --src "./_index/" --dst "./JAV/"
```

## Supported Filename Patterns

The parser handles common variants such as:

```text
(MKBD S130) KIRARI 130 Chie Aoi.mp4
(MKBD S141) KIRARI 141_2 Mahoro Yoshino.mp4
MKBD-S89 KIRARI 89 Kaori Maeda.mp4
[MKBD S119] KIRARI 119 Yua Ariga.mp4
Mkbd S108 Kirari 108 The Best Collection 3hrs 16girls_1080p.mp4
ABP-123 Example Title.mp4
SSIS001 Another Title.mkv
XYZ 456 part2.mp4
default ABP-123 Example Title.mp4
```

Normalized results:

```text
(MKBD S130) KIRARI 130 Chie Aoi.mp4
-> JAV/MKBD/MKBD-S130.mp4

(MKBD S141) KIRARI 141_2 Mahoro Yoshino.mp4
-> JAV/MKBD/MKBD-S141 - pt2.mp4

ABP-123 Example Title.mp4
-> JAV/ABP/ABP-123.mp4

XYZ 456 part2.mp4
-> JAV/XYZ/XYZ-456 - pt2.mp4
```

## How Matching Works

The script:

1. Reads every file under the source tree.
2. Filters to known video extensions: `mp4`, `mkv`, `avi`, `mov`, `m4v`, `wmv`, `ts`, `m2ts`, `mpg`, `mpeg`, `flv`, `webm`.
3. Extracts a prefix and code from the filename.
4. Detects an optional part number.
5. Chooses one source per normalized title when duplicates exist.
6. Creates the destination link unless that path already exists.

If the destination directory is inside the source directory, the destination tree is automatically excluded from scanning to avoid reprocessing generated links.

## Duplicate Handling

Files that normalize to the same output name are treated as duplicates. The script keeps the largest source file for that title and counts the others as skipped duplicates in the summary.

## Snapshot and Tombstoning

After every real run (not dry-run), the script writes a snapshot of every file currently sitting under `DST/<PREFIX>/<FILE>` to `DST/.jav_snapshot`. The snapshot is additive: entries from the previous snapshot are merged with the current on-disk listing and deduplicated. Snapshot entries are stored as relative paths such as `ABP/ABP-123.mp4`.

With `--skip-deleted`, the script reads the snapshot before linking and builds a tombstone set of entries that are in the snapshot but no longer exist on disk. Any planned output that matches a tombstone is skipped and counted as `Skipped (tombstoned)` in the summary. This lets you delete a link you do not want without having it recreated on the next run.

Related options:

- `--snapshot FILE` uses a custom snapshot path instead of `DST/.jav_snapshot`.
- `--no-snapshot` disables both reading and writing the snapshot entirely.

The snapshot file itself is excluded from both scanning and snapshotting.

## Example

Source tree:

```text
_movie/
├── _index/
│   ├── MKBD-Sxx [Uncensored]/
│   │   ├── (MKBD S130) KIRARI 130 Chie Aoi.mp4
│   │   ├── (MKBD S141) KIRARI 141_2 Mahoro Yoshino.mp4
│   │   └── MKBD-S89 KIRARI 89 Kaori Maeda.mp4
│   ├── ABP/
│   │   └── ABP-123 Example Title.mp4
│   └── SSIS/
│       └── SSIS001 Another Title.mkv
└── JAV/
```

Command:

```bash
./make_jav_links.sh --dry-run
```

Sample output:

```text
would link: /absolute/path/_movie/JAV/MKBD/MKBD-S130.mp4 -> /absolute/path/_movie/_index/MKBD-Sxx [Uncensored]/(MKBD S130) KIRARI 130 Chie Aoi.mp4
would link: /absolute/path/_movie/JAV/MKBD/MKBD-S141 - pt2.mp4 -> /absolute/path/_movie/_index/MKBD-Sxx [Uncensored]/(MKBD S141) KIRARI 141_2 Mahoro Yoshino.mp4
would link: /absolute/path/_movie/JAV/MKBD/MKBD-S89.mp4 -> /absolute/path/_movie/_index/MKBD-Sxx [Uncensored]/MKBD-S89 KIRARI 89 Kaori Maeda.mp4
would link: /absolute/path/_movie/JAV/ABP/ABP-123.mp4 -> /absolute/path/_movie/_index/ABP/ABP-123 Example Title.mp4
would link: /absolute/path/_movie/JAV/SSIS/SSIS-001.mkv -> /absolute/path/_movie/_index/SSIS/SSIS001 Another Title.mkv

Summary
-------
Scanned files        : 5
Candidates           : 5
Unique titles        : 5
Links created        : 5
Skipped (exists)     : 0
Skipped (parse fail) : 0
Skipped (non-video)  : 0
Skipped (duplicate)  : 0
Link mode            : symlink
Dry run              : 1
```

## Notes

- Symbolic links work across filesystems; hard links do not.
- Hard links require source and destination to be on the same filesystem.
- Existing destination files are never overwritten.
- Filenames that do not match the parser are skipped and counted as parse failures.

## Repository Contents

```text
.
├── make_jav_links.sh
└── readme.md
```

## License

Use freely for personal media organization.
