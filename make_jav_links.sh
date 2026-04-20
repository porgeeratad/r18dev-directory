#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

SCRIPT_NAME="$(basename "$0")"

SRC="_movie/_index"
DST="_movie/JAV"
LINK_MODE="symlink"
DRY_RUN=0

SCANNED=0
CANDIDATES=0
LINKED=0
SKIPPED_EXISTS=0
SKIPPED_PARSE=0
SKIPPED_NONVIDEO=0
SKIPPED_DUPLICATE=0
SKIPPED_TOMBSTONE=0

SNAPSHOT=""
NO_SNAPSHOT=0
SKIP_DELETED=0

TAB=$'\t'

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [OPTIONS] [SRC] [DST]

Create organized links under JAV/<PREFIX>/ from indexed video files.

Options:
  -n, --dry-run     Show what would be created without making changes
      --hardlink    Use hard links instead of symbolic links
      --symlink     Use symbolic links (default)
      --src DIR     Source root directory (default: $SRC)
      --dst DIR     Destination root directory (default: $DST)
      --snapshot FILE
                    Path to snapshot file of destination filenames
                    (default: DST/.jav_snapshot)
      --no-snapshot Do not read or write the snapshot file
      --skip-deleted
                    Skip creating links for outputs listed in the snapshot
                    that have since been removed from DST (treat as tombstones
                    so user-intentional deletions are not reintroduced)
  -h, --help        Show this help message

Examples:
  $SCRIPT_NAME
  $SCRIPT_NAME "_movie/_index" "_movie/JAV"
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --src "_movie/_index" --dst "_movie/JAV"
  $SCRIPT_NAME --hardlink
EOF
}

abs_path_any() {
  local p="$1"
  local dir base
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  echo "$(cd "$dir" && pwd -P)/$base"
}

to_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_part_num() {
  local raw="$1"
  printf '%d' "$((10#$raw))"
}

file_size() {
  local f="$1"

  if stat -c%s "$f" >/dev/null 2>&1; then
    stat -c%s "$f"
  elif stat -f%z "$f" >/dev/null 2>&1; then
    stat -f%z "$f"
  else
    wc -c < "$f" | tr -d ' '
  fi
}

is_video_file() {
  local file="$1"
  local ext
  ext="$(to_lower "${file##*.}")"

  case "$ext" in
    mp4|mkv|avi|mov|m4v|wmv|ts|m2ts|mpg|mpeg|flv|webm)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

strip_leading_noise() {
  local s="$1"
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(default[[:space:]]*)+//I')"
  printf '%s' "$s"
}

detect_part() {
  local remainder="$1"
  local code_tail="$2"
  local lower_rem lower_code numeric re

  lower_rem="$(to_lower "$remainder")"
  lower_code="$(to_lower "$code_tail")"
  numeric="$(printf '%s' "$code_tail" | tr -cd '0-9')"

  re='(^|[^[:alnum:]])(cd|disc|part|pt)[[:space:]_.-]*([0-9]+)($|[^[:alnum:]])'
  if [[ "$lower_rem" =~ $re ]]; then
    normalize_part_num "${BASH_REMATCH[3]}"
    return 0
  fi

  re="(^|[^[:alnum:]])${lower_code}[_.-]+([0-9]+)($|[^[:alnum:]])"
  if [[ "$lower_rem" =~ $re ]]; then
    normalize_part_num "${BASH_REMATCH[2]}"
    return 0
  fi

  if [[ -n "$numeric" ]]; then
    re="(^|[^[:digit:]])${numeric}[_.-]+([0-9]+)($|[^[:digit:]])"
    if [[ "$lower_rem" =~ $re ]]; then
      normalize_part_num "${BASH_REMATCH[2]}"
      return 0
    fi
  fi

  printf '%s' ""
}

parse_filename() {
  local base="$1"
  local name prefix token matched part code_tail remainder re

  name="${base%.*}"
  name="$(strip_leading_noise "$name")"

  prefix=""
  token=""
  matched=""
  part=""
  code_tail=""
  remainder=""

  # Pattern 1:
  # (MKBD S130) ...
  # [MKBD S119] ...
  # MKBD-S89 ...
  # Mkbd S108 ...
  re='^[[:space:]\(\[]*([A-Za-z]{2,6})[[:space:]_-]+([A-Za-z]*[0-9]+([_-][0-9]+)?)'
  if [[ "$name" =~ $re ]]; then
    prefix="$(to_upper "${BASH_REMATCH[1]}")"
    token="${BASH_REMATCH[2]}"
    matched="${BASH_REMATCH[0]}"
  else
    # Pattern 2:
    # ABC123 ...
    re='^[[:space:]\(\[]*([A-Za-z]{2,6})([0-9]+([_-][0-9]+)?)'
    if [[ "$name" =~ $re ]]; then
      prefix="$(to_upper "${BASH_REMATCH[1]}")"
      token="${BASH_REMATCH[2]}"
      matched="${BASH_REMATCH[0]}"
    else
      return 1
    fi
  fi

  if [[ "$token" =~ ^([A-Za-z]*[0-9]+)[_-]([0-9]+)$ ]]; then
    code_tail="$(to_upper "${BASH_REMATCH[1]}")"
    part="$(normalize_part_num "${BASH_REMATCH[2]}")"
  else
    code_tail="$(to_upper "$token")"
  fi

  remainder="${name#"$matched"}"
  if [[ -z "$part" ]]; then
    part="$(detect_part "$remainder" "$code_tail")"
  fi

  printf '%s\t%s\t%s\n' "$prefix" "$code_tail" "$part"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run)
      DRY_RUN=1
      shift
      ;;
    --hardlink)
      LINK_MODE="hardlink"
      shift
      ;;
    --symlink)
      LINK_MODE="symlink"
      shift
      ;;
    --src)
      [[ $# -ge 2 ]] || { echo "error: --src requires a value" >&2; exit 1; }
      SRC="$2"
      shift 2
      ;;
    --dst)
      [[ $# -ge 2 ]] || { echo "error: --dst requires a value" >&2; exit 1; }
      DST="$2"
      shift 2
      ;;
    --snapshot)
      [[ $# -ge 2 ]] || { echo "error: --snapshot requires a value" >&2; exit 1; }
      SNAPSHOT="$2"
      shift 2
      ;;
    --no-snapshot)
      NO_SNAPSHOT=1
      shift
      ;;
    --skip-deleted)
      SKIP_DELETED=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      if [[ "$SRC" == "_movie/_index" ]]; then
        SRC="$1"
      elif [[ "$DST" == "_movie/JAV" ]]; then
        DST="$1"
      else
        echo "error: too many positional arguments" >&2
        usage >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ ! -d "$SRC" ]]; then
  echo "error: source directory not found: $SRC" >&2
  exit 1
fi

SRC_ABS="$(abs_path_any "$SRC")"

if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$DST"
fi

DST_ABS="$(abs_path_any "$DST")"

if [[ $NO_SNAPSHOT -eq 0 && -z "$SNAPSHOT" ]]; then
  SNAPSHOT="$DST_ABS/.jav_snapshot"
fi

TMP_ALL="$(mktemp)"
TMP_BEST="$(mktemp)"
TMP_SNAP=""
TMP_TOMB=""

cleanup() {
  rm -f "$TMP_ALL" "$TMP_BEST"
  [[ -n "$TMP_SNAP" ]] && rm -f "$TMP_SNAP"
  [[ -n "$TMP_TOMB" ]] && rm -f "$TMP_TOMB"
}
trap cleanup EXIT

if [[ $SKIP_DELETED -eq 1 && $NO_SNAPSHOT -eq 0 && -n "$SNAPSHOT" && -f "$SNAPSHOT" ]]; then
  TMP_TOMB="$(mktemp)"
  while IFS= read -r rel_prev; do
    [[ -z "$rel_prev" ]] && continue
    if [[ ! -e "$DST_ABS/$rel_prev" && ! -L "$DST_ABS/$rel_prev" ]]; then
      printf '%s\n' "$rel_prev" >> "$TMP_TOMB"
    fi
  done < "$SNAPSHOT"
fi

scan_files() {
  if [[ "$DST_ABS" == "$SRC_ABS" || "$DST_ABS" == "$SRC_ABS"/* ]]; then
    find "$SRC_ABS" \
      \( -path "$DST_ABS" -o -path "$DST_ABS/*" \) -prune -o \
      -type f ! -name '.DS_Store' -print0
  else
    find "$SRC_ABS" -type f ! -name '.DS_Store' -print0
  fi
}

while IFS= read -r -d '' f; do
  ((SCANNED+=1))
  base="$(basename "$f")"

  if ! is_video_file "$base"; then
    ((SKIPPED_NONVIDEO+=1))
    continue
  fi

  if ! parsed="$(parse_filename "$base")"; then
    echo "skip (parse failed): $base" >&2
    ((SKIPPED_PARSE+=1))
    continue
  fi

  IFS=$'\t' read -r prefix code_tail part <<< "$parsed"
  ext="$(to_lower "${base##*.}")"
  src_abs="$(abs_path_any "$f")"
  size="$(file_size "$f")"

  part_store="${part:--}"
  key="${prefix}|${code_tail}|${part_store}"

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$key" "$size" "$prefix" "$code_tail" "$part_store" "$ext" "$src_abs" \
    >> "$TMP_ALL"

  ((CANDIDATES+=1))
done < <(scan_files)

if [[ ! -s "$TMP_ALL" ]]; then
  echo
  echo "Summary"
  echo "-------"
  echo "Scanned files        : $SCANNED"
  echo "Candidates           : 0"
  echo "Unique titles        : 0"
  echo "Links created        : 0"
  echo "Skipped (exists)     : 0"
  echo "Skipped (tombstoned) : 0"
  echo "Skipped (parse fail) : $SKIPPED_PARSE"
  echo "Skipped (non-video)  : $SKIPPED_NONVIDEO"
  echo "Skipped (duplicate)  : 0"
  echo "Link mode            : $LINK_MODE"
  echo "Dry run              : $DRY_RUN"
  if [[ $NO_SNAPSHOT -eq 1 ]]; then
    echo "Snapshot             : disabled"
  else
    echo "Snapshot file        : $SNAPSHOT"
    echo "Skip-deleted         : $SKIP_DELETED"
  fi
  exit 0
fi

sort -t "$TAB" -k1,1 -k2,2nr "$TMP_ALL" | awk -F '\t' '!seen[$1]++' > "$TMP_BEST"

UNIQUE_TITLES="$(wc -l < "$TMP_BEST" | tr -d ' ')"
SKIPPED_DUPLICATE=$((CANDIDATES - UNIQUE_TITLES))

while IFS=$'\t' read -r key size prefix code_tail part ext src_abs; do
  [[ -n "${key:-}" ]] || continue

  if [[ "$part" == "-" ]]; then
    part=""
  fi

  outdir="$DST_ABS/$prefix"
  if [[ -n "$part" ]]; then
    outname="${prefix}-${code_tail} - pt${part}.${ext}"
  else
    outname="${prefix}-${code_tail}.${ext}"
  fi
  dst_file="$outdir/$outname"

  if [[ -e "$dst_file" || -L "$dst_file" ]]; then
    echo "skip (exists): $dst_file"
    ((SKIPPED_EXISTS+=1))
    continue
  fi

  rel_out="$prefix/$outname"
  if [[ -n "$TMP_TOMB" ]] && grep -Fxq -- "$rel_out" "$TMP_TOMB"; then
    echo "skip (tombstoned, user-deleted): $dst_file"
    ((SKIPPED_TOMBSTONE+=1))
    continue
  fi

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "would link: $dst_file -> $src_abs"
    ((LINKED+=1))
    continue
  fi

  mkdir -p "$outdir"

  if [[ "$LINK_MODE" == "hardlink" ]]; then
    ln "$src_abs" "$dst_file"
  else
    ln -s "$src_abs" "$dst_file"
  fi

  echo "linked: $dst_file"
  ((LINKED+=1))
done < "$TMP_BEST"

SNAPSHOT_WRITTEN=0
if [[ $DRY_RUN -eq 0 && $NO_SNAPSHOT -eq 0 && -n "$SNAPSHOT" ]]; then
  TMP_SNAP="$(mktemp)"
  if [[ -d "$DST_ABS" ]]; then
    ( cd "$DST_ABS" \
      && find . -mindepth 2 -maxdepth 2 \( -type f -o -type l \) \
           ! -name '.DS_Store' ! -name '.jav_snapshot' 2>/dev/null \
      | sed 's|^\./||' ) >> "$TMP_SNAP"
  fi
  if [[ -f "$SNAPSHOT" ]]; then
    cat "$SNAPSHOT" >> "$TMP_SNAP"
  fi
  mkdir -p "$(dirname "$SNAPSHOT")"
  sort -u "$TMP_SNAP" > "$SNAPSHOT"
  SNAPSHOT_WRITTEN=1
fi

echo
echo "Summary"
echo "-------"
echo "Scanned files        : $SCANNED"
echo "Candidates           : $CANDIDATES"
echo "Unique titles        : $UNIQUE_TITLES"
echo "Links created        : $LINKED"
echo "Skipped (exists)     : $SKIPPED_EXISTS"
echo "Skipped (tombstoned) : $SKIPPED_TOMBSTONE"
echo "Skipped (parse fail) : $SKIPPED_PARSE"
echo "Skipped (non-video)  : $SKIPPED_NONVIDEO"
echo "Skipped (duplicate)  : $SKIPPED_DUPLICATE"
echo "Link mode            : $LINK_MODE"
echo "Dry run              : $DRY_RUN"
if [[ $NO_SNAPSHOT -eq 1 ]]; then
  echo "Snapshot             : disabled"
else
  echo "Snapshot file        : $SNAPSHOT"
  echo "Snapshot written     : $SNAPSHOT_WRITTEN"
  echo "Skip-deleted         : $SKIP_DELETED"
fi
