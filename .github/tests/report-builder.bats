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


# ═══════════════════════════════════════════════════════════════════════════
# Database changes (API vs Database labelling)
# ═══════════════════════════════════════════════════════════════════════════

# run_builder <repo_dir> <base> <head> [extra_db_paths]
run_builder() {
  cd "$1"
  export BASE="$2" HEAD="$3"
  export REPO_NAME="folio-org/mod-db-test"
  export EXTRA_PATHS=""
  export EXTRA_DB_PATHS="${4:-}"
  export REPORT_FILE="$TEST_TMP/db_report.md"
  unset GITHUB_STEP_SUMMARY
  run bash "$SCRIPT_DIR/report-builder.sh"
  echo "OUTPUT: $output"
  [[ "$status" -eq 0 ]]
}

# new_repo <name> → creates repo, cd's into it
new_repo() {
  DB_REPO="$TEST_TMP/$1"
  git init -q "$DB_REPO"
  cd "$DB_REPO"
}

@test "db-report: RMB schema.json + sql change is labelled Database, API untouched" {
  new_repo mod-rmb
  mkdir -p src/main/resources/templates/db_scripts
  echo '{"scripts":[]}' > src/main/resources/templates/db_scripts/schema.json
  echo 'CREATE TABLE a (id int);' > src/main/resources/templates/db_scripts/a.sql
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo '{"scripts":[{"run":"after"}]}' > src/main/resources/templates/db_scripts/schema.json
  echo 'CREATE TABLE a (id int, name text);' > src/main/resources/templates/db_scripts/a.sql
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "— Database" "$REPORT_FILE"
  grep -q "RMB schema.json" "$REPORT_FILE"
  grep -q "RMB script" "$REPORT_FILE"
  grep -q "^| Database | 2 |" "$REPORT_FILE"
  grep -q "^| API (JSON schemas) | 0 |" "$REPORT_FILE"
  ! grep -q "— API" "$REPORT_FILE"
  grep -q "+CREATE TABLE a (id int, name text);" "$REPORT_FILE"
}

@test "db-report: Liquibase (db/changelog) and multi-module -server path detected" {
  new_repo mod-lb
  mkdir -p src/main/resources/db/changelog/changes mod-x-server/src/main/resources/liquibase/tenant/scripts
  echo '<databaseChangeLog/>' > src/main/resources/db/changelog/changelog-master.xml
  echo 'a' > mod-x-server/src/main/resources/liquibase/tenant/scripts/.keep
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo '<databaseChangeLog><include file="changes/v1.xml"/></databaseChangeLog>' > src/main/resources/db/changelog/changelog-master.xml
  echo '<databaseChangeLog/>' > src/main/resources/db/changelog/changes/v1.xml
  echo 'ALTER TABLE t ADD c int;' > mod-x-server/src/main/resources/liquibase/tenant/scripts/v1.sql
  echo 'b' > mod-x-server/src/main/resources/liquibase/tenant/scripts/.keep
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "src/main/resources/db/changelog/changelog-master.xml" "$REPORT_FILE"
  grep -q "src/main/resources/db/changelog/changes/v1.xml" "$REPORT_FILE"
  grep -q "mod-x-server/src/main/resources/liquibase/tenant/scripts/v1.sql" "$REPORT_FILE"
  grep -q "Liquibase changelog" "$REPORT_FILE"
  # .keep files are ignored
  ! grep -q "\.keep" "$REPORT_FILE"
  grep -q "^| Database | 3 |" "$REPORT_FILE"
}

@test "db-report: API and DB changes land in separate labelled sections" {
  new_repo mod-mixed
  mkdir -p ramls/schemas src/main/resources/templates/db_scripts
  echo '{"type":"object"}' > ramls/schemas/item.json
  echo '{"scripts":[]}' > src/main/resources/templates/db_scripts/schema.json
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo '{"type":"object","properties":{"id":{"type":"string"}}}' > ramls/schemas/item.json
  echo '{"scripts":[{"run":"before"}]}' > src/main/resources/templates/db_scripts/schema.json
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "^### Changed files — API" "$REPORT_FILE"
  grep -q "^### Schema changes — API" "$REPORT_FILE"
  grep -q "^### Changed files — Database" "$REPORT_FILE"
  grep -q "^### Schema changes — Database" "$REPORT_FILE"
  grep -q "^| API (JSON schemas) | 1 |" "$REPORT_FILE"
  grep -q "^| Database | 1 |" "$REPORT_FILE"
  # API section comes before the Database section
  local api_ln db_ln
  api_ln=$(grep -n "^### Changed files — API" "$REPORT_FILE" | cut -d: -f1)
  db_ln=$(grep -n "^### Changed files — Database" "$REPORT_FILE" | cut -d: -f1)
  (( api_ln < db_ln ))
  # schema.json is NOT duplicated in the API section
  [[ $(grep -c '^#### `src/main/resources/templates/db_scripts/schema.json`' "$REPORT_FILE") -eq 1 ]]
}

@test "db-report: no DB changes → explicit note, zero count" {
  new_repo mod-nodb
  mkdir -p ramls/schemas
  echo '{"type":"object"}' > ramls/schemas/item.json
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo '{"type":"string"}' > ramls/schemas/item.json
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "No database changes detected" "$REPORT_FILE"
  grep -q "^| Database | 0 |" "$REPORT_FILE"
  grep -q "^| API (JSON schemas) | 1 |" "$REPORT_FILE"
}

@test "db-report: Flyway migration, renamed and deleted DB files" {
  new_repo mod-fw
  mkdir -p src/main/resources/db/migration
  echo 'CREATE TABLE a(id int);' > src/main/resources/db/migration/V1__init.sql
  echo 'SELECT 1; SELECT 2; SELECT 3; SELECT 4; SELECT 5;' > src/main/resources/db/migration/V2__old.sql
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  git mv src/main/resources/db/migration/V2__old.sql src/main/resources/db/migration/V2__renamed.sql
  git rm -q src/main/resources/db/migration/V1__init.sql
  echo 'ALTER TABLE a ADD c int;' > src/main/resources/db/migration/V3__alter.sql
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "Flyway migration" "$REPORT_FILE"
  grep -q "Deleted" "$REPORT_FILE"
  grep -q "Added" "$REPORT_FILE"
  grep -q "Renamed" "$REPORT_FILE"
  grep -q "V2__renamed.sql" "$REPORT_FILE"
}

@test "db-report: EXTRA_DB_PATHS adds custom database locations" {
  new_repo mod-extra
  mkdir -p src/main/resources/custom
  echo 'a,1' > src/main/resources/custom/seed.csv
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo 'a,2' > src/main/resources/custom/seed.csv
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H" ""
  grep -q "No database changes detected" "$REPORT_FILE"

  run_builder "$DB_REPO" "$B" "$H" "src/main/resources/custom/**"
  grep -q "src/main/resources/custom/seed.csv" "$REPORT_FILE"
  grep -q "^| Database | 1 |" "$REPORT_FILE"
}

@test "db-report: GITHUB_STEP_SUMMARY receives the full report with summary" {
  new_repo mod-summary
  mkdir -p src/main/resources/templates/db_scripts
  echo '{"scripts":[]}' > src/main/resources/templates/db_scripts/schema.json
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  echo '{"scripts":[1]}' > src/main/resources/templates/db_scripts/schema.json
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  export GITHUB_STEP_SUMMARY="$TEST_TMP/step_summary.md"
  : > "$GITHUB_STEP_SUMMARY"
  BASE="$B" HEAD="$H" REPO_NAME="folio-org/mod-summary" EXTRA_PATHS="" REPORT_FILE="$TEST_TMP/r.md" \
    run bash "$SCRIPT_DIR/report-builder.sh"
  [[ "$status" -eq 0 ]]
  diff "$TEST_TMP/r.md" "$GITHUB_STEP_SUMMARY"
  grep -q "^| Database | 1 |" "$GITHUB_STEP_SUMMARY"
}

@test "db-report: loose SQL (resources root, db/scripts, repo scripts/) is detected, test SQL is not" {
  new_repo mod-sql
  mkdir -p src/main/resources/db/scripts scripts/ops src/test/resources
  echo 'a' > src/main/resources/template_create_tenant.sql
  echo 'a' > src/main/resources/db/scripts/truncate.sql
  echo 'a' > scripts/ops/delete_ids.sql
  echo 'a' > src/test/resources/fixture.sql
  git add -A && git commit -q -m base; local B; B=$(git rev-parse HEAD)
  for f in src/main/resources/template_create_tenant.sql src/main/resources/db/scripts/truncate.sql scripts/ops/delete_ids.sql src/test/resources/fixture.sql; do echo b > $f; done
  git add -A && git commit -q -m head; local H; H=$(git rev-parse HEAD)

  run_builder "$DB_REPO" "$B" "$H"

  grep -q "src/main/resources/template_create_tenant.sql" "$REPORT_FILE"
  grep -q "src/main/resources/db/scripts/truncate.sql" "$REPORT_FILE"
  grep -q "scripts/ops/delete_ids.sql" "$REPORT_FILE"
  ! grep -q "fixture.sql" "$REPORT_FILE"
  grep -q "^| Database | 3 |" "$REPORT_FILE"
}
