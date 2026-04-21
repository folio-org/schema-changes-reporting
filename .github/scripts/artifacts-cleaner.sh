#!/usr/bin/env bash
# Deletes per-module `mod-*` artifacts from the current workflow run
# (called after the combined report has been built).
#
# Inputs (env): GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID

set -Eeuo pipefail

REPO="${GITHUB_REPOSITORY:?}"
RUN_ID="${GITHUB_RUN_ID:?}"

ARTIFACT_IDS=$(gh api "/repos/${REPO}/actions/runs/${RUN_ID}/artifacts" \
  --paginate -q '.artifacts[] | select(.name | startswith("mod-")) | "\(.id) \(.name)"')

if [[ -z "$ARTIFACT_IDS" ]]; then
  echo "No per-module artifacts found to delete"
  exit 0
fi

echo "Artifacts to delete:"
echo "$ARTIFACT_IDS"

echo "$ARTIFACT_IDS" | while read -r AID ANAME; do
  echo "Deleting artifact ${ANAME} (${AID})..."
  if gh api -X DELETE "/repos/${REPO}/actions/artifacts/${AID}"; then
    echo "  ✓ Deleted"
  else
    echo "  ✗ Failed to delete (may require admin permissions)"
  fi
done

