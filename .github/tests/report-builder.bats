#!/usr/bin/env bats
# Integration tests for report-builder.sh
# Tests the filtering logic with a real git repo + submodule.

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"

setup() {
  TEST_TMP="$(mktemp -d)"

  # Allow file:// protocol for local submodule tests (git >= 2.38)
  _OLD_FILE_ALLOW="$(git config --global --get protocol.file.allow 2>/dev/null || true)"
  git config --global protocol.file.allow always

  # ── Create a "submodule" repo simulating acq-models ──────────────────
  export SM_REPO="$TEST_TMP/acq-models-upstream"
  git init -q "$SM_REPO"
  cd "$SM_REPO"

  # Base commit: three modules with schemas
  mkdir -p mod-orgs/schemas common/schemas mod-finance/schemas
  cat > mod-orgs/schemas/organization.json <<'EOF'
{
  "type": "object",
  "properties": {
    "id": { "$ref": "../../common/schemas/uuid.json" },
    "name": { "type": "string" }
  }
}
EOF
  echo '{"type":"string","pattern":"^[0-9a-f-]{36}$"}' > common/schemas/uuid.json
  echo '{"type":"object","properties":{"amount":{"type":"number"}}}' > mod-finance/schemas/budget.json
  echo '{"type":"string"}' > common/schemas/tags.json
  git add -A && git commit -q -m "base schemas"
  SM_BASE=$(git rev-parse HEAD)

  # Head commit: modify org + add unrelated finance schema
  cat > mod-orgs/schemas/organization.json <<'EOF'
{
  "type": "object",
  "properties": {
    "id": { "$ref": "../../common/schemas/uuid.json" },
    "name": { "type": "string" },
    "code": { "type": "string" }
  }
}
EOF
  echo '{"type":"object","properties":{"amount":{"type":"number"},"currency":{"type":"string"}}}' > mod-finance/schemas/budget.json
  echo '{"type":"string","description":"updated"}' > common/schemas/tags.json
  git add -A && git commit -q -m "update schemas"
  SM_HEAD=$(git rev-parse HEAD)

  # ── Create the parent repo (mod-organizations-storage) ───────────────
  export PARENT_REPO="$TEST_TMP/mod-organizations-storage"
  git init -q "$PARENT_REPO"
  cd "$PARENT_REPO"


  # Add the submodule
  mkdir -p ramls
  git submodule add -q "$SM_REPO" ramls/acq-models
  cd ramls/acq-models && git checkout -q "$SM_BASE" && cd "$PARENT_REPO"

  # Create RAML files that reference only mod-orgs schemas
  cat > ramls/organization.raml <<'EOF'
#%RAML 1.0
title: Organizations
types:
  organization: !include acq-models/mod-orgs/schemas/organization.json
EOF

  git add -A && git commit -q -m "base"
  export TAG_BASE=$(git rev-parse HEAD)

  # Update submodule pointer to HEAD
  cd ramls/acq-models && git checkout -q "$SM_HEAD" && cd "$PARENT_REPO"
  git add -A && git commit -q -m "update submodule"
  export TAG_HEAD=$(git rev-parse HEAD)
}

teardown() {
  cd /tmp  # ensure we're not inside a deleted directory
  rm -rf "$TEST_TMP"
  # Restore original protocol.file.allow
  if [[ -n "${_OLD_FILE_ALLOW:-}" ]]; then
    git config --global protocol.file.allow "$_OLD_FILE_ALLOW"
  else
    git config --global --unset protocol.file.allow 2>/dev/null || true
  fi
}

@test "build-schema-report: filters out unrelated submodule schemas" {
  cd "$PARENT_REPO"
  export BASE="$TAG_BASE"
  export HEAD="$TAG_HEAD"
  export REPO_NAME="folio-org/mod-organizations-storage"
  export EXTRA_PATHS=""
  export REPORT_FILE="$TEST_TMP/report.md"
  unset GITHUB_STEP_SUMMARY

  run bash "$SCRIPT_DIR/report-builder.sh"
  echo "OUTPUT: $output"
  [[ "$status" -eq 0 ]]

  # Report should include organization.json (modified, mod-orgs)
  grep -q "organization.json" "$REPORT_FILE"

  # Report should include uuid.json (referenced by organization.json via $ref)
  # uuid.json was NOT modified between commits, so it might not appear
  # But it IS in the relevant files list

  # Report should NOT include mod-finance/schemas/budget.json
  ! grep -q "mod-finance" "$REPORT_FILE"

  # Report should NOT include common/schemas/tags.json (not referenced by mod-orgs)
  ! grep -q "tags.json" "$REPORT_FILE"
}

@test "build-schema-report: includes transitively referenced shared schema if changed" {
  cd "$PARENT_REPO"

  # Modify uuid.json (which IS referenced by organization.json)
  cd ramls/acq-models
  echo '{"type":"string","pattern":"^[0-9a-f-]{36}$","description":"UUID v4"}' > common/schemas/uuid.json
  git add -A && git commit -q -m "update uuid"
  SM_HEAD2=$(git rev-parse HEAD)
  cd "$PARENT_REPO"
  git add -A && git commit -q -m "update sm again"
  local TAG_HEAD2
  TAG_HEAD2=$(git rev-parse HEAD)

  export BASE="$TAG_BASE"
  export HEAD="$TAG_HEAD2"
  export REPO_NAME="folio-org/mod-organizations-storage"
  export EXTRA_PATHS=""
  export REPORT_FILE="$TEST_TMP/report2.md"
  unset GITHUB_STEP_SUMMARY

  run bash "$SCRIPT_DIR/report-builder.sh"
  echo "OUTPUT: $output"
  [[ "$status" -eq 0 ]]

  # uuid.json IS referenced and IS changed — should appear
  grep -q "uuid.json" "$REPORT_FILE"
  # organization.json modified — should appear
  grep -q "organization.json" "$REPORT_FILE"
  # mod-finance still filtered out
  ! grep -q "mod-finance" "$REPORT_FILE"
}

@test "build-schema-report: no submodule changes → clean report" {
  cd "$PARENT_REPO"
  # Compare same commit to itself
  export BASE="$TAG_HEAD"
  export HEAD="$TAG_HEAD"
  export REPO_NAME="folio-org/mod-organizations-storage"
  export EXTRA_PATHS=""
  export REPORT_FILE="$TEST_TMP/report3.md"
  unset GITHUB_STEP_SUMMARY

  run bash "$SCRIPT_DIR/report-builder.sh"
  [[ "$status" -eq 0 ]]

  # Should indicate no changes
  grep -q "No JSON schema changes" "$REPORT_FILE"
}

@test "build-schema-report: direct schemas (no submodule) reported correctly" {
  # Create a simple repo with direct schemas (like mod-inventory-storage)
  local SIMPLE_REPO="$TEST_TMP/mod-simple"
  git init -q "$SIMPLE_REPO"
  cd "$SIMPLE_REPO"

  mkdir -p ramls/schemas
  echo '{"type":"object"}' > ramls/schemas/item.json
  git add -A && git commit -q -m "base"
  local SBASE
  SBASE=$(git rev-parse HEAD)

  echo '{"type":"object","properties":{"id":{"type":"string"}}}' > ramls/schemas/item.json
  git add -A && git commit -q -m "update"
  local SHEAD
  SHEAD=$(git rev-parse HEAD)

  export BASE="$SBASE"
  export HEAD="$SHEAD"
  export REPO_NAME="folio-org/mod-simple"
  export EXTRA_PATHS=""
  export REPORT_FILE="$TEST_TMP/report4.md"
  unset GITHUB_STEP_SUMMARY

  run bash "$SCRIPT_DIR/report-builder.sh"
  [[ "$status" -eq 0 ]]

  grep -q "item.json" "$REPORT_FILE"
  grep -q "Modified" "$REPORT_FILE"
}

