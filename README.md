# combine.sh

A Bash script that concatenates every **text** file in a directory into one
`combined.txt`, wrapping each in `===== START / END =====` markers and skipping
binary files. Built by merging the strongest ideas from eight separate
implementations.

```bash
./combine.sh            # combine all text files in the current directory
./combine.sh '*.log'    # only files matching a glob
```

---

## Why it skips what it skips

Binary detection is **encoding-based**: it asks `file --mime-encoding` and skips
only files reported as `binary`. This is the key design choice — it keeps
structured text like **JSON, XML, SVG, and source code**, which a `--mime-type`
+ `text/*` check would silently drop (JSON reports as `application/json`, etc.).

A file is added only if it is a regular file, readable, under the size cap, and
not detected as binary.

---

## Configuration

Everything is an environment variable with a sane default, so you rarely need to
edit the script itself. Override per-run:

| Variable | Default | Purpose |
|----------|---------|---------|
| `OUTPUT` | `combined.txt` | Output filename (in the current directory). |
| `VERBOSE` | `true` | `true` prints an `ADDING:` line per file. Skips/errors always show. |
| `NO_COLOR` | `false` | `true` disables ANSI colors. Colors also auto-disable when output isn't a terminal. |
| `MAX_SIZE` | `52428800` (50 MB) | Per-file size cap in bytes. Set `0` for unlimited. |
| `INCLUDE_HIDDEN` | `false` | `true` also includes dotfiles. |
| *positional* `$1` | `*` | Optional glob pattern to match. |

Examples:
```bash
OUTPUT=all.txt ./combine.sh
MAX_SIZE=0 ./combine.sh                 # no size limit
NO_COLOR=true VERBOSE=false ./combine.sh '*.md'
INCLUDE_HIDDEN=true ./combine.sh
```

Run `./combine.sh --help` for the built-in usage summary.

---

## How the script is laid out

The file is organized in clearly-commented blocks. Here's what each does and
what you'd touch to change behavior.

### 1. `set -uo pipefail` (top)
`-u` catches typos in variable names. **`-e` is deliberately omitted**: with
`-e`, the first file that fails any command would abort the entire run. Instead
the script checks each operation and records failures, so one bad file never
stops the rest. *If you add `-e`, expect the script to bail on the first
oddity.*

### 2. CONFIG block
All the variables in the table above, each written as `VAR="${VAR:-default}"`
so the environment wins. **Change defaults here** if you don't want to pass env
vars every time.

### 3. Help (`-h|--help`)
Prints the comment header at the top of the file. If you reword the header,
adjust the `sed -n '2,30p'` line range to match.

### 4. Colors + logging helpers
- Colors are set only when `NO_COLOR=false` **and** stdout is a terminal
  (`-t 1`), so redirected/piped output never gets escape-code noise.
- `info()` prints only when `VERBOSE=true` (stdout); `warn()` and `error()`
  always print to **stderr**. That means you can do `./combine.sh > out 2> log`
  and get progress vs. problems in separate streams.
- They use `printf '%s'`, not `echo -e` or `printf '%b'`, so a filename
  containing a backslash is never reinterpreted. **Keep `%s`** if you edit these.

### 5. Pre-flight
Checks that the `file` utility exists (the whole detection depends on it) and
defines `filesize()`, which tries GNU `stat -c%s` then BSD/macOS `stat -f%z`
then falls back to `0`. **This is the cross-platform seam** — if you target only
Linux you could simplify it, but leaving it costs nothing.

### 6. Master header
Writes the `# Combined text files / Source directory / Generated / Pattern…`
banner and, by doing so, **creates/truncates `OUTPUT` up front**. This is also
where a failure to write the output aborts early. To change what metadata the
combined file records, edit the `printf` lines here.

### 7. `find` predicate (array `find_args`)
Built as an array, then run via **`find … -print0` piped through process
substitution** (`done < <(find …)`):
- `-print0` + `IFS= read -r -d ''` handles filenames with spaces, newlines, or
  leading dashes.
- **Process substitution (not a normal pipe)** keeps the loop in the current
  shell, which is why the `added/skipped/failed` counters survive — a piped
  `while` would run in a subshell and lose them.
- Hidden files are excluded with `! -name '.*'` unless `INCLUDE_HIDDEN=true`.
- A non-`*` pattern adds `-name "$PATTERN"`.

To **change the search scope** (e.g. recurse into subdirectories), this is the
block to edit — remove `-maxdepth 1`, but be aware START/END markers would then
need path-aware names.

### 8. The per-file loop
In order, each candidate is checked for: name == output (skip), readable
(`-r`), size cap, then binary encoding. Survivors are appended as:
```
===== START: <file> =====
<contents>
===== END: <file> =====
```
The **leading `\n` in the END `printf`** is deliberate: it guarantees the END
marker starts on its own line even when a file has no trailing newline (a
classic corruption bug). **Don't remove that `\n`.** Counters use
`x=$((x + 1))` rather than `((x++))` on purpose — the latter returns a non-zero
status when the value is `0`, which can bite under stricter shell settings.

### 9. Summary
Prints `Added / Skipped / Failed / Output (bytes)` and warns if nothing was
combined. The byte count comes from `wc -c` on the finished output.

---

## Behaviors worth knowing

- **The script includes itself.** If `combine.sh` lives in the directory being
  combined, it ends up in the output (only `combined.txt` is auto-excluded). To
  exclude the script too, add near the top of the loop:
  ```bash
  [[ "$file" == "$(basename "$0")" ]] && continue
  ```
- **Running as root skips the permission check**, because root can read any
  file regardless of mode bits. That's expected; for normal users the
  `no read permission` skip works (verified).
- **Exit code is `0` even if individual files failed** — check the summary's
  `Failed:` count, or capture stderr. A non-zero exit is reserved for fatal
  setup problems (missing `file`, unwritable output).
- **Ordering** follows `find`'s traversal order, which is not guaranteed
  alphabetical. To sort, pipe through `sort -z`:
  ```bash
  done < <(find "${find_args[@]}" -print0 2>/dev/null | sort -z)
  ```

---

## Quick reference: common edits

| I want to… | Edit |
|------------|------|
| Change default output name | `OUTPUT=` in CONFIG (or run with `OUTPUT=...`) |
| Drop the 50 MB cap | `MAX_SIZE=0` (env) or change the default |
| Include dotfiles | `INCLUDE_HIDDEN=true` |
| Recurse into subfolders | Remove `-maxdepth 1` in the `find_args` block (§7) |
| Exclude the script itself | Add the `basename` guard (see above) |
| Sort files alphabetically | Add `| sort -z` after `find` (§9 note) |
| Different START/END markers | The two `printf` lines in the loop (§8) |
| Stricter abort-on-error | Add `-e` to `set` (§1) — understand the trade-off |

---

## License

MIT — use, modify, and share freely.
