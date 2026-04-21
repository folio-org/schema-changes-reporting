#!/usr/bin/env bash
# Builds a Markdown report of JSON schema changes between two refs for a
# FOLIO module repository, including changes inside git submodules.
#
# Inputs (env):
#   BASE, HEAD           - refs to compare (required)
#   REPO_NAME            - e.g. "folio-org/mod-users"
#   EXTRA_PATHS          - optional space-separated pathspec globs
#   REPORT_FILE          - output file (default: report.md)
#   GITHUB_STEP_SUMMARY  - GH Actions step summary path (optional)

set -Eeuo pipefail

BASE="${BASE:?BASE is required}"
HEAD="${HEAD:?HEAD is required}"
REPO_NAME="${REPO_NAME:-${GITHUB_REPOSITORY:-unknown/unknown}}"
EXTRA_PATHS="${EXTRA_PATHS:-}"
REPORT_FILE="${REPORT_FILE:-report.md}"
MAX_LINES="${MAX_LINES:-500}"

MODULE_NAME="${REPO_NAME##*/}"

# ── Temp dir with automatic cleanup ─────────────────────────────────────
TMPDIR_SCHEMA="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_SCHEMA"' EXIT
mkfile() { mktemp "$TMPDIR_SCHEMA/$1.XXXXXX"; }

: > "$REPORT_FILE"

# ── Output helpers ───────────────────────────────────────────────────────

# out
# Writes stdin to report file (and step summary if available).
out()  { if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then tee -a "$REPORT_FILE" >> "$GITHUB_STEP_SUMMARY"; else tee -a "$REPORT_FILE" >/dev/null; fi; }

# emit <line...>
# Writes lines to the report.
emit() { printf '%s\n' "$@" | out; }

# truncate_or_all <file> [max_lines]
# Prints file content; truncates with a note if it exceeds max_lines.
truncate_or_all() {
  local LINES; LINES=$(wc -l < "$1" || echo 0)
  if (( LINES > MAX_LINES )); then
    head -n "$MAX_LINES" "$1"
    echo "_Output truncated to ${MAX_LINES} lines._"
  else
    cat "$1"
  fi
}

# status_label <git_status_code>
# Converts git diff status letters to human-readable labels.
status_label() {
  case "$1" in
    M)  echo "Modified" ;;
    A)  echo "Added" ;;
    D)  echo "Deleted" ;;
    R*) echo "Renamed (${1#R}%)" ;;
    C*) echo "Copied (${1#C}%)" ;;
    T)  echo "Type changed" ;;
    U)  echo "Unmerged" ;;
    X)  echo "Unknown" ;;
    B)  echo "Broken pairing" ;;
    *)  echo "$1" ;;
  esac
}

# ── Per-file diff ────────────────────────────────────────────────────────

# diff_schema_file <git_dir> <base_ref> <head_ref> <status> <path_a> <path_b> <display_prefix>
# Diffs a single file (normalized JSON first, raw fallback) and appends to report.
diff_schema_file() {
  local GIT_DIR="$1" BASE_REF="$2" HEAD_REF="$3" S="$4" A="$5" B="$6" PREFIX="$7"

  local BASE_PATH="$A" HEAD_PATH="$A" TITLE="${PREFIX}${A}"
  [[ "$S" == R* ]] && { HEAD_PATH="$B"; TITLE="${PREFIX}${B}"; }

  emit "#### \`$TITLE\`"

  local BASE_RAW HEAD_RAW
  BASE_RAW="$(mkfile base_raw)"; HEAD_RAW="$(mkfile head_raw)"
  git -C "$GIT_DIR" show "$BASE_REF:$BASE_PATH" 2>/dev/null > "$BASE_RAW" || : > "$BASE_RAW"
  git -C "$GIT_DIR" show "$HEAD_REF:$HEAD_PATH" 2>/dev/null > "$HEAD_RAW" || : > "$HEAD_RAW"

  local BASE_NORM HEAD_NORM VALID_BASE=1 VALID_HEAD=1
  BASE_NORM="$(mkfile base_json)"; HEAD_NORM="$(mkfile head_json)"
  jq -S . < "$BASE_RAW" > "$BASE_NORM" 2>/dev/null || { VALID_BASE=0; echo '{}' > "$BASE_NORM"; }
  jq -S . < "$HEAD_RAW" > "$HEAD_NORM" 2>/dev/null || { VALID_HEAD=0; echo '{}' > "$HEAD_NORM"; }

  local NORM_DIFF; NORM_DIFF="$(mkfile norm_diff)"
  if ! diff -u --label "$TITLE (base)" --label "$TITLE (head)" \
       "$BASE_NORM" "$HEAD_NORM" > "$NORM_DIFF"; then
    emit '```diff'
    truncate_or_all "$NORM_DIFF" | out
    emit '```'
  else
    (( VALID_BASE == 0 || VALID_HEAD == 0 )) \
      && emit "_Note: one of the versions is not valid JSON — raw diff only._"
    emit "_No structural changes (after normalization)_" ""

    local RAW_DIFF; RAW_DIFF="$(mkfile raw_diff)"
    diff -u --label "$TITLE (base)" --label "$TITLE (head)" \
      "$BASE_RAW" "$HEAD_RAW" > "$RAW_DIFF" || true

    if [[ -s "$RAW_DIFF" ]]; then
      emit "_Showing raw textual diff (formatting/whitespace changes may appear)_"
      emit '```diff'
      truncate_or_all "$RAW_DIFF" | out
      emit '```'
    else
      emit "_Files are identical._"
    fi
  fi
  emit ""
}

# ── Section renderer ─────────────────────────────────────────────────────

# render_section <status_file> <git_dir> <base_ref> <head_ref> <section_title> <display_prefix>
# Renders "Changed files" table + per-file diffs for a given status file.
render_section() {
  local STATUS_FILE="$1" GIT_DIR="$2" BASE_REF="$3" HEAD_REF="$4" TITLE="$5" PREFIX="$6"

  emit "### Changed files${TITLE:+ $TITLE}" \
       "" \
       "| Status | File (HEAD) |" \
       "|---|---|"

  local -a CHANGES=()
  while IFS= read -r LINE; do CHANGES+=("$LINE"); done < "$STATUS_FILE"

  local LINE S A B FILE
  for LINE in "${CHANGES[@]}"; do
    IFS=$'\t' read -r S A B <<< "$LINE"
    FILE="$A"; [[ "$S" == R* ]] && FILE="$B"
    emit "| $(status_label "$S") | \`${PREFIX}${FILE}\` |"
  done

  emit "" \
       "### Schema changes${TITLE:+ $TITLE}" \
       ""

  for LINE in "${CHANGES[@]}"; do
    IFS=$'\t' read -r S A B <<< "$LINE"
    diff_schema_file "$GIT_DIR" "$BASE_REF" "$HEAD_REF" "$S" "$A" "$B" "$PREFIX"
  done
}

# ── Report header ────────────────────────────────────────────────────────
emit "## JSON Schema Changes (\`$REPO_NAME\`)" \
     "" \
     "- Base: \`$BASE\`" \
     "- Head: \`$HEAD\`" \
     ""

HAS_CHANGES=0

# ── Part 1: Direct JSON schema files ────────────────────────────────────
PATHSPECS=( ':(glob)ramls/**/*.json' ':!ramls/examples/' ':!ramls/raml-util/' )
for EXTRA in $EXTRA_PATHS; do PATHSPECS+=( ":(glob)${EXTRA}" ); done

git -c diff.renames=true diff --name-status -M "$BASE" "$HEAD" \
  -- "${PATHSPECS[@]}" > "$TMPDIR_SCHEMA/status.txt" || true

if [[ -s "$TMPDIR_SCHEMA/status.txt" ]]; then
  HAS_CHANGES=1
  render_section "$TMPDIR_SCHEMA/status.txt" "." "$BASE" "$HEAD" "" ""
fi

# ── Part 2: Schemas inside git submodules ────────────────────────────────
# Some FOLIO modules store JSON schemas in submodules under ramls/
# (e.g. ramls/acq-models, ramls/raml-storage). A normal diff on the parent
# repo only sees the submodule-pointer commit change. We enter each
# submodule and diff JSON schemas between the old and new commit.
#
# Submodules like acq-models contain schemas for MANY modules;
# we only report changes relevant to the current repository.

echo "Module name for submodule filtering: $MODULE_NAME"

GITMODULES_CONTENT=$(git show "$HEAD:.gitmodules" 2>/dev/null || true)
[[ -z "$GITMODULES_CONTENT" ]] && {
  (( HAS_CHANGES == 0 )) && emit "_No JSON schema changes detected (checked direct files and submodules)._"
  exit 0
}

# ── Extract submodule paths from .gitmodules ─────────────────────────────
mapfile -t SUBMODULE_PATHS < <(
  echo "$GITMODULES_CONTENT" \
    | awk -F'=' '/^[[:space:]]*path[[:space:]]*=/ {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2 }'
)

for SM_PATH in "${SUBMODULE_PATHS[@]}"; do
  [[ -z "$SM_PATH" ]] && continue
  # Skip raml-util (shared utility, not module schemas)
  [[ "$SM_PATH" == *raml-util* ]] && continue

  echo "::group::Checking submodule: $SM_PATH"

  SM_BASE_COMMIT=$(git ls-tree "$BASE" -- "$SM_PATH" 2>/dev/null | awk '{print $3}' || true)
  SM_HEAD_COMMIT=$(git ls-tree "$HEAD" -- "$SM_PATH" 2>/dev/null | awk '{print $3}' || true)

  echo "  Submodule $SM_PATH: base=$SM_BASE_COMMIT head=$SM_HEAD_COMMIT"

  if [[ -z "$SM_HEAD_COMMIT" && -z "$SM_BASE_COMMIT" ]]; then
    echo "  Submodule not present at either ref — skipping"; echo "::endgroup::"; continue
  fi
  if [[ "$SM_BASE_COMMIT" == "$SM_HEAD_COMMIT" ]]; then
    echo "  Submodule pointer unchanged — skipping"; echo "::endgroup::"; continue
  fi

  SM_DIR="$SM_PATH"
  if [[ ! -d "$SM_DIR/.git" && ! -f "$SM_DIR/.git" ]]; then
    echo "  Submodule not checked out, attempting init..."
    git submodule update --init --recursive -- "$SM_PATH" 2>/dev/null || true
  fi
  if [[ ! -d "$SM_DIR/.git" && ! -f "$SM_DIR/.git" ]]; then
    echo "  ⚠ Cannot access submodule at $SM_DIR — skipping"; echo "::endgroup::"; continue
  fi

  # ── Fetch required commits ─────────────────────────────────────────────
  # Fetch only the specific commits we need; fall back to full fetch
  # if origin refuses to serve commit SHAs directly.
  sm_has_commit() { git -C "$SM_DIR" cat-file -t "$1" >/dev/null 2>&1; }

  for SHA in "$SM_BASE_COMMIT" "$SM_HEAD_COMMIT"; do
    [[ -z "$SHA" ]] && continue
    sm_has_commit "$SHA" && continue
    git -C "$SM_DIR" fetch --quiet --no-tags --depth=1 origin "$SHA" 2>/dev/null \
      || git -C "$SM_DIR" fetch --quiet --tags origin 2>/dev/null || true
  done

  if [[ -n "$SM_BASE_COMMIT" ]] && ! sm_has_commit "$SM_BASE_COMMIT"; then
    echo "  ⚠ Base commit $SM_BASE_COMMIT not available in submodule — skipping"
    echo "::endgroup::"; continue
  fi
  if [[ -n "$SM_HEAD_COMMIT" ]] && ! sm_has_commit "$SM_HEAD_COMMIT"; then
    echo "  ⚠ Head commit $SM_HEAD_COMMIT not available in submodule — skipping"
    echo "::endgroup::"; continue
  fi

  # ── Handle added/removed submodules ────────────────────────────────────
  EMPTY_TREE=""
  [[ -z "$SM_BASE_COMMIT" || -z "$SM_HEAD_COMMIT" ]] \
    && EMPTY_TREE="$(git -C "$SM_DIR" hash-object -t tree /dev/null)"
  [[ -z "$SM_BASE_COMMIT" ]] && SM_BASE_COMMIT="$EMPTY_TREE"
  [[ -z "$SM_HEAD_COMMIT" ]] && SM_HEAD_COMMIT="$EMPTY_TREE"

  # ── Step 1: Collect parent-repo refs pointing into this submodule ──────
  # Trace $ref / !include from the parent repo's schemas into the submodule
  # to find exactly which files this module actually uses.
  PARENT_SCHEMAS_REFS="$TMPDIR_SCHEMA/parent_refs_into_sm.txt"
  : > "$PARENT_SCHEMAS_REFS"

  # add_sm_ref <resolved_path>
  # Adds a submodule-internal path to the refs list (deduped).
  add_sm_ref() {
    local RESOLVED="$1"
    if [[ "$RESOLVED" == "${SM_PATH}/"* ]]; then
      local SM_INTERNAL="${RESOLVED#"${SM_PATH}/"}"
      if ! grep -qxF "$SM_INTERNAL" "$PARENT_SCHEMAS_REFS" 2>/dev/null; then
        echo "$SM_INTERNAL" >> "$PARENT_SCHEMAS_REFS"
      fi
    fi
  }

  # ── Step 1a: Scan .json files (outside submodule) for $ref ─────────────
  PARENT_JSON_FILES=$(git ls-tree -r --name-only "$HEAD" -- "ramls/" 2>/dev/null \
    | grep '\.json$' | grep -v "^${SM_PATH}/" || true)

  for PF in $PARENT_JSON_FILES; do
    PF_CONTENT=$(git show "$HEAD:$PF" 2>/dev/null || true)
    [[ -z "$PF_CONTENT" ]] && continue

    PF_REFS=$(echo "$PF_CONTENT" | jq -r '
      .. | objects | select(has("$ref")) | .["$ref"] // empty
    ' 2>/dev/null | grep '\.json' | sed 's/#.*//' | sort -u || true)

    PF_DIR=$(dirname "$PF")
    for REF in $PF_REFS; do
      RESOLVED=$(python3 -c "
import os.path, sys
print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))" \
        "$PF_DIR" "$REF" 2>/dev/null || true)
      [[ -z "$RESOLVED" ]] && continue
      RESOLVED="${RESOLVED#./}"
      add_sm_ref "$RESOLVED"
    done
  done

  # ── Step 1b: Scan .raml files for !include pointing into submodule ─────
  PARENT_RAML_FILES=$(git ls-tree -r --name-only "$HEAD" -- "ramls/" 2>/dev/null \
    | grep '\.raml$' | grep -v "^${SM_PATH}/" || true)

  for RF in $PARENT_RAML_FILES; do
    RF_CONTENT=$(git show "$HEAD:$RF" 2>/dev/null || true)
    [[ -z "$RF_CONTENT" ]] && continue

    INCLUDES=$(echo "$RF_CONTENT" \
      | sed -nE 's/.*!include[[:space:]]+([^[:space:]]*\.json).*/\1/p' \
      | sort -u || true)

    RF_DIR=$(dirname "$RF")
    for INC in $INCLUDES; do
      RESOLVED=$(python3 -c "
import os.path, sys
print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))" \
        "$RF_DIR" "$INC" 2>/dev/null || true)
      [[ -z "$RESOLVED" ]] && continue
      RESOLVED="${RESOLVED#./}"
      add_sm_ref "$RESOLVED"
    done
  done

  echo "  Direct refs from parent repo into submodule:"
  if [[ -s "$PARENT_SCHEMAS_REFS" ]]; then
    sed 's/^/    /' "$PARENT_SCHEMAS_REFS"
  else
    echo "    (none found — will show all submodule changes)"
  fi

  # ── Step 2: BFS to find all transitively referenced files ──────────────
  RELEVANT_FILES="$TMPDIR_SCHEMA/relevant_sm_files.txt"
  : > "$RELEVANT_FILES"
  HAS_RELEVANT_FILTER=false

  if [[ -s "$PARENT_SCHEMAS_REFS" ]]; then
    HAS_RELEVANT_FILTER=true
    VISITED="$TMPDIR_SCHEMA/visited_refs.txt"
    : > "$VISITED"
    QUEUE="$TMPDIR_SCHEMA/ref_queue.txt"
    cp "$PARENT_SCHEMAS_REFS" "$QUEUE"

    while [[ -s "$QUEUE" ]]; do
      NEXT_QUEUE="$TMPDIR_SCHEMA/ref_queue_next.txt"
      : > "$NEXT_QUEUE"

      while IFS= read -r SCHEMA_FILE; do
        [[ -z "$SCHEMA_FILE" ]] && continue
        grep -qxF "$SCHEMA_FILE" "$VISITED" 2>/dev/null && continue
        echo "$SCHEMA_FILE" >> "$VISITED"
        echo "$SCHEMA_FILE" >> "$RELEVANT_FILES"

        SCHEMA_CONTENT=$(git -C "$SM_DIR" show "$SM_HEAD_COMMIT:$SCHEMA_FILE" 2>/dev/null || true)
        [[ -z "$SCHEMA_CONTENT" ]] && continue

        # Extract $ref values pointing to .json files (strip fragment)
        REFS=$(echo "$SCHEMA_CONTENT" | jq -r '
          .. | objects | select(has("$ref")) | .["$ref"] // empty
        ' 2>/dev/null | grep '\.json' | sed 's/#.*//' | sort -u || true)

        SCHEMA_DIR=$(dirname "$SCHEMA_FILE")
        for REF in $REFS; do
          RESOLVED=$(python3 -c "
import os.path, sys
print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))" \
            "$SCHEMA_DIR" "$REF" 2>/dev/null || true)
          [[ -z "$RESOLVED" ]] && continue
          RESOLVED="${RESOLVED#./}"

          if ! grep -qxF "$RESOLVED" "$VISITED" 2>/dev/null; then
            echo "$RESOLVED" >> "$NEXT_QUEUE"
          fi
        done
      done < "$QUEUE"

      mv "$NEXT_QUEUE" "$QUEUE"
    done

    echo "  All relevant submodule files (after BFS, ${MODULE_NAME}):"
    wc -l < "$RELEVANT_FILES" | xargs -I{} echo "    {} file(s)"
  fi

  # ── Step 3: Get full diff in submodule ─────────────────────────────────
  git -C "$SM_DIR" -c diff.renames=true diff --name-status -M \
    "$SM_BASE_COMMIT" "$SM_HEAD_COMMIT" \
    -- '*.json' ':!examples/' ':!**/examples/' > "$TMPDIR_SCHEMA/sm_status_raw.txt" || true

  if [[ ! -s "$TMPDIR_SCHEMA/sm_status_raw.txt" ]]; then
    echo "  No JSON schema changes in submodule"
    echo "::endgroup::"; continue
  fi

  # ── Step 4: Filter — keep only files in RELEVANT_FILES ─────────────────
  if [[ "$HAS_RELEVANT_FILTER" == "true" ]]; then
    : > "$TMPDIR_SCHEMA/sm_status.txt"
    while IFS= read -r LINE; do
      IFS=$'\t' read -r S A B <<< "$LINE"
      FILE="$A"; [[ "$S" == R* ]] && FILE="$B"

      if grep -qxF "$FILE" "$RELEVANT_FILES" 2>/dev/null; then
        echo "$LINE" >> "$TMPDIR_SCHEMA/sm_status.txt"
      # Also check the source path for renames
      elif [[ "$S" == R* ]] && grep -qxF "$A" "$RELEVANT_FILES" 2>/dev/null; then
        echo "$LINE" >> "$TMPDIR_SCHEMA/sm_status.txt"
      fi
    done < "$TMPDIR_SCHEMA/sm_status_raw.txt"
  else
    # No filter available — fall back to showing all
    cp "$TMPDIR_SCHEMA/sm_status_raw.txt" "$TMPDIR_SCHEMA/sm_status.txt"
  fi

  if [[ ! -s "$TMPDIR_SCHEMA/sm_status.txt" ]]; then
    echo "  No relevant JSON schema changes after filtering for $MODULE_NAME"
    echo "::endgroup::"; continue
  fi

  # ── Render submodule section ───────────────────────────────────────────
  HAS_CHANGES=1
  SM_LABEL="$SM_PATH"
  emit "### Changed files in submodule \`$SM_LABEL\`" \
       "" \
       "- Submodule base commit: \`$SM_BASE_COMMIT\`" \
       "- Submodule head commit: \`$SM_HEAD_COMMIT\`" \
       "" \
       "| Status | File (HEAD) |" \
       "|---|---|"

  while IFS= read -r LINE; do
    IFS=$'\t' read -r S A B <<< "$LINE"
    FILE="$A"; [[ "$S" == R* ]] && FILE="$B"
    emit "| $(status_label "$S") | \`${SM_LABEL}/${FILE}\` |"
  done < "$TMPDIR_SCHEMA/sm_status.txt"

  emit "" \
       "### Schema changes in submodule \`$SM_LABEL\`" \
       ""

  while IFS= read -r LINE; do
    IFS=$'\t' read -r S A B <<< "$LINE"
    diff_schema_file "$SM_DIR" "$SM_BASE_COMMIT" "$SM_HEAD_COMMIT" \
      "$S" "$A" "$B" "${SM_LABEL}/"
  done < "$TMPDIR_SCHEMA/sm_status.txt"

  echo "::endgroup::"
done

if (( HAS_CHANGES == 0 )); then
  emit "_No JSON schema changes detected (checked direct files and submodules)._"
fi

