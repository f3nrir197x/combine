#!/usr/bin/env bash
#
# combine.sh — Concatenate every text file in a directory into one output file,
#              skipping binary files. Each file is wrapped in START/END markers.
#
# Detection is encoding-based (file --mime-encoding != binary), so structured
# text such as JSON, XML, SVG and source code is KEPT, not dropped.
#
# Usage:
#   ./combine.sh [PATTERN]
#       PATTERN   optional glob to match (default: *). Example: ./combine.sh '*.log'
#
# Options are environment variables (see the CONFIG block below):
#   OUTPUT  VERBOSE  NO_COLOR  MAX_SIZE  INCLUDE_HIDDEN
#
# Examples:
#   ./combine.sh                       # combine all text files in the current dir
#   OUTPUT=all.txt ./combine.sh        # write to all.txt instead of combined.txt
#   MAX_SIZE=0 ./combine.sh            # no size limit
#   NO_COLOR=true VERBOSE=false ./combine.sh '*.md'
#
# Exit codes: 0 = ran (see summary for per-file failures); 1 = fatal setup error.

set -uo pipefail   # -u: catch unset vars. NOTE: -e is intentionally omitted so a
                   # single problem file cannot abort the whole run (we track and
                   # report per-file failures instead).

# ----------------------------------------------------------------------------
# CONFIG (override via environment variables)
# ----------------------------------------------------------------------------
OUTPUT="${OUTPUT:-combined.txt}"          # output filename (in current dir)
VERBOSE="${VERBOSE:-true}"                # true = print each ADD line
NO_COLOR="${NO_COLOR:-false}"             # true = never emit ANSI colors
MAX_SIZE="${MAX_SIZE:-$((50 * 1024 * 1024))}"  # per-file cap in bytes; 0 = unlimited
INCLUDE_HIDDEN="${INCLUDE_HIDDEN:-false}" # true = also include dotfiles
PATTERN="${1:-*}"                         # optional positional glob

# ----------------------------------------------------------------------------
# Help
# ----------------------------------------------------------------------------
case "${1:-}" in
    -h|--help)
        sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
        exit 0
        ;;
esac

# ----------------------------------------------------------------------------
# Colors — disabled when NO_COLOR=true or stdout is not a terminal (so piped or
# redirected output never gets polluted with escape codes).
# ----------------------------------------------------------------------------
if [[ "$NO_COLOR" == "true" || ! -t 1 ]]; then
    GREEN=''; YELLOW=''; RED=''; NC=''
else
    GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; NC=$'\033[0m'
fi

# %s (not %b) so colors render but filenames are never reinterpreted.
info()  { [[ "$VERBOSE" == "true" ]] && printf '%s\n' "${GREEN}$*${NC}" || true; }
warn()  { printf '%s\n' "${YELLOW}$*${NC}" >&2; }
error() { printf '%s\n' "${RED}$*${NC}" >&2; }

# ----------------------------------------------------------------------------
# Pre-flight
# ----------------------------------------------------------------------------
if ! command -v file >/dev/null 2>&1; then
    error "Required utility 'file' is not installed. Install it and re-run."
    exit 1
fi

# portable file size (GNU stat -c, then BSD/macOS stat -f, then 0)
filesize() {
    stat -c%s -- "$1" 2>/dev/null || stat -f%z -- "$1" 2>/dev/null || echo 0
}

# ----------------------------------------------------------------------------
# Write the master header (this also creates/truncates OUTPUT up front).
# ----------------------------------------------------------------------------
{
    printf '# Combined text files\n'
    printf '# Source directory : %s\n' "$(pwd)"
    printf '# Generated        : %s\n' "$(date)"
    printf '# Pattern: %s | Max size: %s bytes | Hidden: %s\n\n' \
           "$PATTERN" "$MAX_SIZE" "$INCLUDE_HIDDEN"
} > "$OUTPUT" || { error "Cannot write to output file: $OUTPUT"; exit 1; }

info "Scanning files (pattern: $PATTERN)..."

# ----------------------------------------------------------------------------
# Build the find predicate. Using find + -print0 + process substitution means:
#   - filenames with spaces/newlines/leading dashes are handled safely, and
#   - the loop runs in THIS shell, so the counters below actually persist.
# ----------------------------------------------------------------------------
find_args=(. -maxdepth 1 -type f)
[[ "$INCLUDE_HIDDEN" != "true" ]] && find_args+=( ! -name '.*' )
[[ "$PATTERN" != "*" ]]          && find_args+=( -name "$PATTERN" )

added=0
skipped=0
failed=0

while IFS= read -r -d '' path; do
    file="${path#./}"                       # strip leading ./
    [[ "$file" == "$OUTPUT" ]] && continue  # never include our own output

    # readable?
    if [[ ! -r "$file" ]]; then
        warn "SKIP (no read permission): $file"
        skipped=$((skipped + 1)); continue
    fi

    # size cap
    size=$(filesize "$file")
    if (( MAX_SIZE > 0 && size > MAX_SIZE )); then
        warn "SKIP (too large: ${size}B > ${MAX_SIZE}B): $file"
        skipped=$((skipped + 1)); continue
    fi

    # encoding-based binary detection
    if ! encoding=$(file -b --mime-encoding -- "$file" 2>/dev/null); then
        error "SKIP (could not inspect): $file"
        failed=$((failed + 1)); continue
    fi
    if [[ "$encoding" == "binary" ]]; then
        warn "SKIP (binary): $file (encoding: $encoding)"
        skipped=$((skipped + 1)); continue
    fi

    info "ADDING: $file ($encoding, ${size}B)"

    # The leading \n before END protects files that lack a trailing newline,
    # so the END marker is never glued onto the file's last line.
    if {
        printf '===== START: %s =====\n' "$file"
        cat -- "$file"
        printf '\n===== END: %s =====\n\n' "$file"
    } >> "$OUTPUT"; then
        added=$((added + 1))
    else
        error "FAILED to append: $file"
        failed=$((failed + 1))
    fi
done < <(find "${find_args[@]}" -print0 2>/dev/null)

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------
total_bytes=$(wc -c < "$OUTPUT" 2>/dev/null || echo 0)
printf '%s\n' "${GREEN}Done.${NC} Added: $added | Skipped: $skipped | Failed: $failed | Output: $OUTPUT (${total_bytes} bytes)"
(( added == 0 )) && warn "No text files were combined."
exit 0
