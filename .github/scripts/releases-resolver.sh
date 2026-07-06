#!/usr/bin/env bash
# Resolves FOLIO module tag versions for two platform-lsp releases.
#
# Inputs (env):
#   INPUT_BASE           - base release tag (empty ⇒ auto-detect 2nd latest)
#   INPUT_HEAD           - head release tag (empty ⇒ auto-detect latest)
#   GH_TOKEN             - GitHub token (for raw.githubusercontent calls)
#   GITHUB_OUTPUT        - path to GH Actions $GITHUB_OUTPUT (optional)
#   MODULES_CONFIG       - path to modules JSON config
#                          (default: .github/config/modules.json)
#
# Output:
#   Writes `modules=<json-array>` to $GITHUB_OUTPUT (if set), where each
#   element is: {name, base, head, base_app, head_app}.

set -Eeuo pipefail

MODULES_CONFIG="${MODULES_CONFIG:-.github/config/modules.json}"
PLATFORM_DIR="${PLATFORM_DIR:-/tmp/platform-lsp}"

mapfile -t TARGET_MODULES < <(jq -r '.modules[]' "$MODULES_CONFIG")

# ── Step 1: Clone platform-lsp ───────────────────────────────────────────
echo "::group::Clone platform-lsp"
rm -rf "$PLATFORM_DIR"
git clone --quiet --filter=blob:none --no-checkout \
  https://github.com/folio-org/platform-lsp.git "$PLATFORM_DIR"
echo "::endgroup::"

# ── Step 2: Determine HEAD / BASE release tags ──────────────────────────
TAGS_WITH_DATES=$(git -C "$PLATFORM_DIR" for-each-ref \
  --sort=-creatordate \
  --format='%(refname:short) %(creatordate:format:%Y-%m-%d)' \
  refs/tags/)

echo "Tags by creation date (newest first):"
echo "$TAGS_WITH_DATES" | head -10 | sed 's/^/  /'

INPUT_HEAD="${INPUT_HEAD:-}"
INPUT_BASE="${INPUT_BASE:-}"

if { [[ -n "$INPUT_HEAD" && -z "$INPUT_BASE" ]] \
  || [[ -z "$INPUT_HEAD" && -n "$INPUT_BASE" ]]; }; then
  echo "::error::Specify both base and head, or leave both empty for auto-detection"
  exit 1
fi

if [[ -n "$INPUT_HEAD" && -n "$INPUT_BASE" ]]; then
  HEAD_RELEASE="$INPUT_HEAD"
  BASE_RELEASE="$INPUT_BASE"
  for TAG in "$HEAD_RELEASE" "$BASE_RELEASE"; do
    if ! echo "$TAGS_WITH_DATES" | awk '{print $1}' | grep -qx "$TAG"; then
      echo "::error::Release tag '${TAG}' not found in platform-lsp"
      echo "Available tags:"
      echo "$TAGS_WITH_DATES" | head -20 | sed 's/^/  /'
      exit 1
    fi
  done
  echo "✓ Using manually specified releases"
else
  HEAD_RELEASE=$(echo "$TAGS_WITH_DATES" | awk 'NR==1 {print $1}')
  BASE_RELEASE=$(echo "$TAGS_WITH_DATES" | awk 'NR==2 {print $1}')
  echo "✓ Auto-detected releases"
fi

[[ -z "$HEAD_RELEASE" ]] && { echo "::error::No tags found in platform-lsp"; exit 1; }
[[ -z "$BASE_RELEASE" ]] && { echo "::error::Only one tag found in platform-lsp — need at least two"; exit 1; }
[[ "$HEAD_RELEASE" == "$BASE_RELEASE" ]] \
  && { echo "::error::HEAD and BASE releases resolved to the same tag: ${HEAD_RELEASE}"; exit 1; }

echo "✓ HEAD release (latest):   ${HEAD_RELEASE}"
echo "✓ BASE release (previous): ${BASE_RELEASE}"

# ── Step 3: Resolve module versions per release ──────────────────────────
declare -A MOD_BASE_TAG MOD_HEAD_TAG MOD_BASE_APP MOD_HEAD_APP

# fetch_template <app_name> <app_version> <out_file>
# Fetches an application module manifest with CONCRETE (pinned) module
# versions; output written to given file (empty file on failure).
#
# Two supported layouts (tried in order):
#   Legacy: "<app>.template.json"      — modules: [ {name, version: "x.y.z"} ]
#   Current: "application.lock.json"   — modules: [ {id, name, version: "x.y.z"} ]
#
# NOTE: the current "application.template.json" is intentionally NOT used —
# it carries version ranges (e.g. "~1.13.1"), not tags. Only the lock file
# has resolved, pinned versions. Both supported files expose
# `.modules[].name` / `.modules[].version`, so downstream parsing is uniform.
fetch_template() {
  local APP_NAME="$1" APP_VERSION="$2" OUT="$3"
  local BASE="https://raw.githubusercontent.com/folio-org/${APP_NAME}/v${APP_VERSION}"
  local CAND
  : > "$OUT"
  for CAND in "${APP_NAME}.template.json" "application.lock.json"; do
    if curl -sf -H "Authorization: token ${GH_TOKEN:-}" \
        "${BASE}/${CAND}" -o "$OUT" 2>/dev/null && [[ -s "$OUT" ]]; then
      return 0
    fi
  done
  : > "$OUT"
}

# resolve_modules_for_release <release_tag> <suffix>
# Resolves target module versions from a given platform-lsp release.
resolve_modules_for_release() {
  local RELEASE_TAG="$1" SUFFIX="$2"

  echo ""
  echo "::group::Resolving modules for release ${RELEASE_TAG} (${SUFFIX})"

  # ── Read applications list (two supported platform-lsp formats) ─────────
  # Legacy (≤ R1-2025-csp-7): install-applications.json
  #   [ { "id": "app-name-x.y.z" }, ... ]
  # Current (≥ R1-2025-csp-8):  platform-descriptor.json
  #   { "applications": { "required": [ {name, version} ],
  #                       "optional": [ {name, version} ] } }
  # Both are normalized to APPS_JSON: [ { "name": ..., "version": ... } ].
  local RAW APPS_SRC APPS_JSON
  if RAW=$(git -C "$PLATFORM_DIR" show \
      "${RELEASE_TAG}:install-applications.json" 2>/dev/null); then
    APPS_SRC="install-applications.json"
    APPS_JSON=$(echo "$RAW" | jq -c '
      [ .[].id
        | capture("^(?<n>.+)-(?<v>[0-9]+\\.[0-9]+\\.[0-9]+(-[A-Za-z0-9.]+)?)$")
        | {name: .n, version: .v} ]')
  elif RAW=$(git -C "$PLATFORM_DIR" show \
      "${RELEASE_TAG}:platform-descriptor.json" 2>/dev/null); then
    APPS_SRC="platform-descriptor.json"
    APPS_JSON=$(echo "$RAW" | jq -c '
      [ ((.applications.required // []) + (.applications.optional // []))[]
        | {name: .name, version: .version} ]')
  else
    echo "::error::Cannot read install-applications.json or platform-descriptor.json at tag ${RELEASE_TAG}"
    echo "::endgroup::"
    return 1
  fi

  echo "Applications in ${RELEASE_TAG} (from ${APPS_SRC}):"
  echo "$APPS_JSON" | jq -r '.[] | "  \(.name)-\(.version)"'
  echo ""

  # ── Parse normalized applications → (name, version) ────────────────────
  local -a APP_NAMES APP_VERSIONS
  while IFS=$'\t' read -r APP_NAME APP_VERSION; do
    [[ -z "$APP_NAME" ]] && continue
    APP_NAMES+=("$APP_NAME")
    APP_VERSIONS+=("$APP_VERSION")
  done < <(echo "$APPS_JSON" | jq -r '.[] | "\(.name)\t\(.version)"')

  # ── Fetch all templates in parallel ────────────────────────────────────
  local TMP
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' RETURN

  local i
  for i in "${!APP_NAMES[@]}"; do
    fetch_template "${APP_NAMES[$i]}" "${APP_VERSIONS[$i]}" "$TMP/app_$i.json" &
    # Throttle to avoid runaway parallelism
    (( (i + 1) % 8 == 0 )) && wait
  done
  wait

  # ── Resolve modules from prefetched templates ──────────────────────────
  local -a REMAINING=("${TARGET_MODULES[@]}")

  for i in "${!APP_NAMES[@]}"; do
    [[ ${#REMAINING[@]} -eq 0 ]] && break

    local APP_NAME="${APP_NAMES[$i]}" APP_VERSION="${APP_VERSIONS[$i]}"
    local TEMPLATE_FILE="$TMP/app_$i.json"
    [[ ! -s "$TEMPLATE_FILE" ]] && continue

    local ALL_MODS
    ALL_MODS=$(jq -r '.modules[]? | "\(.name) \(.version)"' < "$TEMPLATE_FILE" 2>/dev/null || true)
    [[ -z "$ALL_MODS" ]] && continue

    # Log this app if it contains at least one target module
    local HAS_TARGET=false MOD
    for MOD in "${REMAINING[@]}"; do
      if echo "$ALL_MODS" | grep -q "^${MOD} "; then HAS_TARGET=true; break; fi
    done

    if [[ "$HAS_TARGET" == "true" ]]; then
      local MOD_COUNT
      MOD_COUNT=$(echo "$ALL_MODS" | wc -l)
      echo "  ┌── ${APP_NAME} v${APP_VERSION} (${MOD_COUNT} modules)"
      echo "$ALL_MODS" | while IFS=' ' read -r MNAME MVER; do
        local MARKER="  │   "
        for TGT in "${TARGET_MODULES[@]}"; do
          [[ "$MNAME" == "$TGT" ]] && { MARKER="  │ ► "; break; }
        done
        echo "${MARKER}${MNAME} v${MVER}"
      done
      echo "  └──"
    fi

    # Resolve remaining target modules from this template
    local -a NEW_REMAINING=()
    for MOD in "${REMAINING[@]}"; do
      local MOD_VERSION
      MOD_VERSION=$(jq -r --arg m "$MOD" \
        '.modules[]? | select(.name == $m) | .version // empty' \
        < "$TEMPLATE_FILE" 2>/dev/null || true)

      if [[ -n "$MOD_VERSION" ]]; then
        echo ""
        echo "  ✓ RESOLVED: ${MOD} v${MOD_VERSION} (from ${APP_NAME} v${APP_VERSION})"
        if [[ "$SUFFIX" == "head" ]]; then
          MOD_HEAD_TAG["$MOD"]="v${MOD_VERSION}"
          MOD_HEAD_APP["$MOD"]="${APP_NAME} v${APP_VERSION}"
        else
          MOD_BASE_TAG["$MOD"]="v${MOD_VERSION}"
          MOD_BASE_APP["$MOD"]="${APP_NAME} v${APP_VERSION}"
        fi
      else
        NEW_REMAINING+=("$MOD")
      fi
    done
    REMAINING=("${NEW_REMAINING[@]+"${NEW_REMAINING[@]}"}")
  done

  if [[ ${#REMAINING[@]} -gt 0 ]]; then
    for MOD in "${REMAINING[@]}"; do
      echo "  ✗ ${MOD} NOT FOUND in any application for ${RELEASE_TAG}"
    done
  fi

  echo "::endgroup::"
}

resolve_modules_for_release "$HEAD_RELEASE" "head"
resolve_modules_for_release "$BASE_RELEASE" "base"

# ── Summary table ────────────────────────────────────────────────────────
echo ""
echo "┌────────────────────────────┬──────────────────────┬──────────────────────┐"
echo "│ Module                     │ base                 │ head                 │"
echo "├────────────────────────────┼──────────────────────┼──────────────────────┤"
for MOD in "${TARGET_MODULES[@]}"; do
  printf "│ %-23s │ %-20s │ %-20s │\n" \
    "$MOD" "${MOD_BASE_TAG[$MOD]:-}" "${MOD_HEAD_TAG[$MOD]:-}"
done
echo "└────────────────────────────┴──────────────────────┴──────────────────────┘"

# ── Build JSON matrix ────────────────────────────────────────────────────
# Only modules resolved in BOTH releases are included.
MODULES_JSON="["
FIRST=true
for MOD in "${TARGET_MODULES[@]}"; do
  BASE_V="${MOD_BASE_TAG[$MOD]:-}"
  HEAD_V="${MOD_HEAD_TAG[$MOD]:-}"
  if [[ -z "$BASE_V" || -z "$HEAD_V" ]]; then
    echo "⚠ Skipping ${MOD} — missing base or head tag"
    continue
  fi
  [[ "$FIRST" != "true" ]] && MODULES_JSON+=","
  FIRST=false
  MODULES_JSON+=$(jq -nc \
    --arg name "$MOD" \
    --arg base "$BASE_V" \
    --arg head "$HEAD_V" \
    --arg base_app "${MOD_BASE_APP[$MOD]:-}" \
    --arg head_app "${MOD_HEAD_APP[$MOD]:-}" \
    '{name:$name,base:$base,head:$head,base_app:$base_app,head_app:$head_app}')
done
MODULES_JSON+="]"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "modules=${MODULES_JSON}" >> "$GITHUB_OUTPUT"
fi

