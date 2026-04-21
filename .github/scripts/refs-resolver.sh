#!/usr/bin/env bash
# Resolves BASE and HEAD git refs for a schema-diff run.
#
# Inputs (env):
#   INPUT_BASE, INPUT_HEAD  - user-provided refs (may be empty)
#   EVENT_NAME              - GITHUB_EVENT_NAME equivalent
#   BEFORE_SHA              - github.event.before (push)
#   PR_BASE_SHA, PR_HEAD_SHA- pull_request base/head SHAs
#   RELEASE_TAG             - github.event.release.tag_name (release)
#   GITHUB_SHA              - current sha
#   GITHUB_OUTPUT           - GH Actions output file (optional)

set -Eeuo pipefail

BASE_IN="${INPUT_BASE:-}"
HEAD_IN="${INPUT_HEAD:-}"

root_commit() { git rev-list --max-parents=0 HEAD | tail -n1; }

case "${EVENT_NAME:-}" in
  push)
    BEFORE="${BEFORE_SHA:-}"
    [[ "$BEFORE" =~ ^0+$ ]] && BEFORE="$(git rev-parse HEAD~1 2>/dev/null || root_commit)"
    BASE="${BASE_IN:-$BEFORE}"
    HEAD="${HEAD_IN:-${GITHUB_SHA}}"
    ;;
  pull_request)
    BASE="${BASE_IN:-${PR_BASE_SHA:-}}"
    HEAD="${HEAD_IN:-${PR_HEAD_SHA:-}}"
    ;;
  release)
    CUR_TAG="${RELEASE_TAG:-}"
    HEAD="${HEAD_IN:-$CUR_TAG}"
    PREV_TAG="$(git tag --sort=-version:refname \
      | awk -v cur="$CUR_TAG" 'found {print; exit} $0==cur {found=1}' || true)"
    [[ -z "$PREV_TAG" ]] && PREV_TAG="$(git tag --sort=version:refname | head -n1 || true)"
    [[ -z "$PREV_TAG" || "$PREV_TAG" == "$CUR_TAG" ]] && PREV_TAG="$(root_commit)"
    BASE="${BASE_IN:-$PREV_TAG}"
    ;;
  workflow_dispatch|workflow_call)
    if [[ -n "$BASE_IN" || -n "$HEAD_IN" ]]; then
      HEAD="${HEAD_IN:-${GITHUB_SHA}}"
      BASE="${BASE_IN:-$(git rev-parse "${HEAD}~1" 2>/dev/null || root_commit)}"
    else
      CUR_TAG="$(git tag --sort=-version:refname | sed -n '1p' || true)"
      PREV_TAG="$(git tag --sort=-version:refname | sed -n '2p' || true)"
      if [[ -n "$CUR_TAG" && -n "$PREV_TAG" ]]; then
        HEAD="$CUR_TAG"; BASE="$PREV_TAG"
      else
        HEAD="${GITHUB_SHA}"
        BASE="$(git rev-parse HEAD~1 2>/dev/null || root_commit)"
      fi
    fi
    ;;
  *)
    HEAD="${HEAD_IN:-${GITHUB_SHA}}"
    BASE="${BASE_IN:-$(git rev-parse HEAD~1 2>/dev/null || root_commit)}"
    ;;
esac

for REF_NAME in BASE HEAD; do
  REF_VAL="${!REF_NAME}"
  if ! git rev-parse --verify "$REF_VAL" >/dev/null 2>&1; then
    echo "::error::${REF_NAME} ref '${REF_VAL}' does not exist in repository"
    exit 1
  fi
done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "base=$BASE"
    echo "head=$HEAD"
  } >> "$GITHUB_OUTPUT"
fi

echo "✓ BASE=$BASE"
echo "✓ HEAD=$HEAD"

