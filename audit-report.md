# r18dev-file-structure Audit Report (Light, 2026-04-27)

## Summary

- **Total findings:** 6 (H: 0, M: 2, L: 4)
- **Snapshot integrity:** PASS

All snapshot integrity checks pass. No high-severity bugs found. Two medium findings affect QNAP deployments and first-time dry-run UX respectively; four low-severity issues cover non-atomic writes, doc drift, and minor inefficiencies.

---

## Findings

### F-01 [M] — `sed //I` case-insensitive flag unsupported on BusyBox sed (QNAP)

**Where:** `make_jav_links.sh:108`
```bash
s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]*(default[[:space:]]*)+//I')"
```

**Observation:** The `I` flag (case-insensitive substitution) is supported by GNU sed and macOS BSD sed, but **not** by BusyBox sed — the `sed` found on QNAP QTS. When the script encounters a file whose name starts with "default" (any case), the subshell running `parse_filename` exits non-zero, and the calling `if !` catches this as a parse failure. The file is silently counted as `Skipped (parse fail)` rather than linked correctly.

**Why it matters:** The script is documented as tested on QNAP 3.2.57. Any filename prefixed with `default …` (e.g. `default ABP-123 title.mp4`) will silently fail on QNAP instead of being normalized. User sees an unexplained parse-failure count in the summary with no filename logged.

**Repro/evidence:** On a QNAP NAS run `./make_jav_links.sh --dry-run` with a file `default ABP-123 title.mp4` in the source. Expected: `would link: .../ABP/ABP-123.mp4`; Actual: `skip (parse failed): default ABP-123 title.mp4` — or a BusyBox `sed: unrecognized option 'I'` error surfaced through `$()`.

**Fix direction** (out-of-scope for this audit): Replace `//I` with a `tr`-based lowercase fold before the match, or add a separate pattern for the uppercased `DEFAULT` prefix.

---

### F-02 [M] — `abs_path_any` fails with opaque error when DST parent doesn't exist in `--dry-run`

**Where:** `make_jav_links.sh:58-64` (function) + call at ~line 272

```bash
abs_path_any() {
  local p="$1"
  local dir base
  dir="$(dirname "$p")"
  base="$(basename "$p")"
  echo "$(cd "$dir" && pwd -P)/$base"
}
...
if [[ $DRY_RUN -eq 0 ]]; then
  mkdir -p "$DST"
fi
DST_ABS="$(abs_path_any "$DST")"   # <── called unconditionally
```

**Observation:** In non-dry-run mode `mkdir -p "$DST"` creates the destination before the `abs_path_any` call. In `--dry-run` mode the `mkdir` is skipped. If the destination's **parent directory** (`dirname "$DST"`) doesn't exist, `cd "$dir"` fails inside the subshell, causing the outer assignment to propagate a non-zero exit code through `set -e`, terminating the script with a generic shell error: `bash: cd: _movie: No such file or directory`.

**Why it matters:** A first-time user exploring `--dry-run` before setting up the directory tree gets a confusing terminal error rather than a clear message. The typical case (`_movie/` exists, `_movie/JAV/` does not) works fine, so this only surfaces for truly fresh environments.

**Repro/evidence:**
```bash
./make_jav_links.sh --dry-run --src /tmp/no_such_src --dst /tmp/no_such_parent/JAV
# bash: line N: cd: /tmp/no_such_parent: No such file or directory
```

**Fix direction:** Guard `abs_path_any "$DST"` so it falls back to `realpath --no-symlinks`-style calculation when the parent doesn't exist, or emit a clear error before the `cd`.

---

### F-03 [L] — Non-atomic snapshot write

**Where:** `make_jav_links.sh:429-443`

```bash
sort -u "$TMP_SNAP" > "$SNAPSHOT"
```

**Observation:** The snapshot file is overwritten by redirecting sorted output directly to `$SNAPSHOT`. If the process is killed (SIGKILL, power loss on the NAS) mid-write, the file is left partially written. On the next run `$SNAPSHOT` may contain truncated JSON — though the snapshot is plain text (one path per line), a truncated last line would cause that entry to be ignored silently, not a hard error.

**Why it matters:** On a NAS where power events are more common, partial snapshot loss means one or more tombstone entries could be forgotten, potentially re-creating a file the user intentionally deleted. The risk is low (partial write drops at most one line) but non-zero.

**Repro/evidence:** Send SIGKILL to the process while snapshot write is in flight. Rarely reproducible in practice.

**Fix direction:** Write to a `.tmp` file then `mv -f "$TMP_SNAP_SORTED" "$SNAPSHOT"` — `mv` is atomic on most filesystems.

---

### F-04 [L] — Vault doc says "Bash 4+" — contradicts repo README "Bash 3.2+"

**Where:** `/vault/system-docs/repos/r18dev-file-structure.md` line 8: `"Requires: Bash 4+, standard Unix tools"` vs. `readme.md` (repo): `"Bash 3.2+ (tested on macOS 3.2.57 and QNAP 3.2.57; no bash 4 features used)"`

**Observation:** The vault system doc states "Bash 4+" as a requirement. The repo README, the handoff doc (`HANDOFF-2026-04-20.md`), and the script itself all affirm Bash 3.2 compatibility with deliberate avoidance of `declare -A`. The vault doc was never updated after the portability decision.

**Why it matters:** Any automation or human referencing the vault doc to check QNAP compatibility would incorrectly conclude the script doesn't run on macOS default bash. Doc drift of this type breeds mistrust in the vault index.

**Repro/evidence:** Compare `/vault/system-docs/repos/r18dev-file-structure.md` (Bash 4+) with `readme.md` (Bash 3.2+).

**Fix direction:** Update vault doc to "Bash 3.2+" (out-of-scope for this audit, noted for vault maintainer).

---

### F-05 [L] — `file_size` runs `stat` twice per file

**Where:** `make_jav_links.sh:79-89`

```bash
file_size() {
  if stat -c%s "$f" >/dev/null 2>&1; then   # probe
    stat -c%s "$f"                            # read
  elif stat -f%z "$f" >/dev/null 2>&1; then  # probe
    stat -f%z "$f"                            # read
  else
    wc -c < "$f" | tr -d ' '
  fi
}
```

**Observation:** Each call probes `stat` once (output discarded) then calls it again to retrieve the value. Every file in the scan incurs two `stat` syscalls (plus a subprocess each time) when either GNU or BSD format is detected.

**Why it matters:** On a NAS with thousands of files the overhead is measurable. No correctness impact.

**Fix direction:** Capture probe output: `if sz="$(stat -c%s "$f" 2>/dev/null)"; then echo "$sz"; elif ...`.

---

### F-06 [L] — Early exit on zero-candidates skips snapshot update

**Where:** `make_jav_links.sh:353-375`

```bash
if [[ ! -s "$TMP_ALL" ]]; then
  ...
  exit 0     # snapshot NOT written
fi
```

**Observation:** When the source directory contains no video candidates, the script exits early before reaching the snapshot write block. If files in `DST` were manually deleted between two runs that both produce zero candidates, the snapshot is never refreshed. On the next non-empty-source run the snapshot still contains the deleted paths, which is actually the desired tombstone behavior — so there is **no data loss**. However the `Skipped (tombstoned)` count would appear on the very next non-empty run even if the user had no intention of tombstoning.

**Why it matters:** Edge-case behavioral surprise, not data corruption. In practice, an empty-source run means the source directory is misconfigured or empty, so this rarely occurs.

---

## Snapshot integrity check

| Check | Result | Notes |
|---|---|---|
| Additive merge across re-run | ✅ PASS | Merges prior snapshot + current on-disk via `sort -u`; no entries dropped |
| Tombstone honored by `--skip-deleted` | ✅ PASS | Tombstone set built before scan; `grep -Fxq` match per candidate; correct skip |
| Dedup key + tie-break sane | ✅ PASS | Key = `PREFIX\|CODE_TAIL\|PART`; sorted by size desc, first-seen kept |
| Multipart `- ptN` handled | ✅ PASS | `detect_part` covers `cd/disc/part/pt` + numeric-suffix patterns; `- pt2` output verified |

---

## Flags / argument walk-through

| Flag | Verified | Notes |
|---|---|---|
| `--dry-run` / `-n` | ✅ | Suppresses `mkdir`, link creation, snapshot write; outputs `would link:` lines |
| `--hardlink` | ✅ | Uses `ln` without `-s`; summary shows `Link mode: hardlink` |
| `--symlink` | ✅ | Default; `ln -s`; explicit flag restores after `--hardlink` in same invocation |
| `--src DIR` | ✅ | Validated with `-d` check; good error message if missing |
| `--dst DIR` | ✅ | `mkdir -p` in real mode; `abs_path_any` parent-existence caveat (F-02) |
| `--snapshot FILE` | ✅ | Overrides default `DST/.jav_snapshot`; `mkdir -p $(dirname …)` before write |
| `--no-snapshot` | ✅ | Sets `NO_SNAPSHOT=1`; skips all snapshot read/write; disables `--skip-deleted` implicitly |
| `--skip-deleted` | ✅ | Tombstone logic correct; only active when snapshot file exists |
| `--help` / `-h` | ✅ | Prints usage to stdout; exits 0 |
| `--` | ✅ | Stops option processing; subsequent positional args handled |
| Unknown option | ✅ | Clear error message + usage to stderr; exits 1 |
