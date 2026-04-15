#!/usr/bin/env bash
# Shared helper functions for schema-changes-reporting scripts.
# Sourced by main scripts and by unit tests.

# ── Output helpers ───────────────────────────────────────────────────────

# truncate_or_all <file> [max_lines]
# Prints file content; if it exceeds max_lines, truncates with a note.
truncate_or_all() {
  local FILE="$1"
  local MAX="${2:-${MAX_LINES:-500}}"
  local LINES
  LINES=$(wc -l < "$FILE" || echo 0)
  if (( LINES > MAX )); then
    head -n "$MAX" "$FILE"
    echo "_Output truncated to ${MAX} lines._"
  else
    cat "$FILE"
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

# ── Path resolution ─────────────────────────────────────────────────────

# resolve_path <base_dir> <relative_path>
# Resolves a relative path against a base directory (like normpath(join(...))).
resolve_path() {
  local BASE_DIR="$1" REL_PATH="$2"
  python3 -c "
import os.path, sys
print(os.path.normpath(os.path.join(sys.argv[1], sys.argv[2])))" \
    "$BASE_DIR" "$REL_PATH" 2>/dev/null || true
}

# ── Ref extraction ───────────────────────────────────────────────────────

# extract_json_refs <json_content>
# Extracts $ref values from JSON schema content (paths to .json files).
extract_json_refs() {
  local CONTENT="$1"
  echo "$CONTENT" | jq -r '
    .. | objects | select(has("$ref")) | .["$ref"] // empty
  ' 2>/dev/null | grep '\.json' | sed 's/#.*//' | sort -u || true
}

# extract_raml_includes <raml_content>
# Extracts !include paths pointing to .json files from RAML content.
extract_raml_includes() {
  local CONTENT="$1"
  echo "$CONTENT" \
    | sed -nE 's/.*!include[[:space:]]+([^[:space:]]*\.json).*/\1/p' \
    | sort -u || true
}

# ── Submodule ref matching ───────────────────────────────────────────────

# is_path_in_submodule <resolved_path> <sm_path>
# Returns 0 (true) if the resolved path points into the given submodule.
is_path_in_submodule() {
  local RESOLVED="$1" SM_PATH="$2"
  [[ "$RESOLVED" == "${SM_PATH}/"* ]]
}

# strip_sm_prefix <resolved_path> <sm_path>
# Strips the submodule prefix to get the internal path.
strip_sm_prefix() {
  local RESOLVED="$1" SM_PATH="$2"
  echo "${RESOLVED#"${SM_PATH}/"}"
}

