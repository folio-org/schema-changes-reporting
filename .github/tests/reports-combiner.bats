#!/usr/bin/env bats
# Unit tests for reports-combiner.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"

setup() {
  TEST_TMP="$(mktemp -d)"
  cd "$TEST_TMP"

  # Create mock reports structure
  mkdir -p reports/mod-orders-storage reports/mod-users
  cat > reports/mod-orders-storage/report.md <<'EOF'
## JSON Schema Changes (`folio-org/mod-orders-storage`)

- Base: `v1.0.0`
- Head: `v2.0.0`

### Changed files (direct)

| Status | File (HEAD) |
|---|---|
| Modified | `ramls/schemas/order.json` |

### Schema changes (direct)

#### `ramls/schemas/order.json`

```diff
-  "status": "string"
+  "status": "enum"
```
EOF

  cat > reports/mod-users/report.md <<'EOF'
## JSON Schema Changes (`folio-org/mod-users`)

_No JSON schema changes detected._
EOF
}

teardown() {
  rm -rf "$TEST_TMP"
}

@test "reports-combiner: produces markdown output" {
  cd "$TEST_TMP"
  export REPORTS_DIR="reports"
  export TIMESTAMP="2025-04-20_12-00-00"

  if ! command -v pandoc &>/dev/null; then
    skip "pandoc not installed"
  fi

  run bash "$SCRIPT_DIR/reports-combiner.sh"
  [[ "$status" -eq 0 ]]

  # Check MD output
  [[ -f "report_2025-04-20_12-00-00.md" ]]
  grep -q "Schema Changes Report" "report_2025-04-20_12-00-00.md"
  grep -q "mod-orders-storage" "report_2025-04-20_12-00-00.md"
  grep -q "mod-users" "report_2025-04-20_12-00-00.md"

  # Check HTML output
  [[ -f "report_2025-04-20_12-00-00.html" ]]
}

@test "reports-combiner: handles single report" {
  cd "$TEST_TMP"
  rm -rf reports/mod-users
  export REPORTS_DIR="reports"
  export TIMESTAMP="2025-01-01_00-00-00"

  if ! command -v pandoc &>/dev/null; then
    skip "pandoc not installed"
  fi

  run bash "$SCRIPT_DIR/reports-combiner.sh"
  [[ "$status" -eq 0 ]]
  [[ -f "report_2025-01-01_00-00-00.md" ]]
  grep -q "mod-orders-storage" "report_2025-01-01_00-00-00.md"
}

@test "reports-combiner: HTML has collapsible details sections" {
  cd "$TEST_TMP"
  export REPORTS_DIR="reports"
  export TIMESTAMP="test"

  if ! command -v pandoc &>/dev/null; then
    skip "pandoc not installed"
  fi

  run bash "$SCRIPT_DIR/reports-combiner.sh"
  [[ "$status" -eq 0 ]]
  [[ -f "report_test.html" ]]
  grep -q "<details" "report_test.html"
  grep -q "<summary>" "report_test.html"
  grep -q "Expand all" "report_test.html"
  grep -q "Collapse all" "report_test.html"
}

@test "reports-combiner: Schema changes sections are nested collapsible details" {
  cd "$TEST_TMP"
  export REPORTS_DIR="reports"
  export TIMESTAMP="nested"

  if ! command -v pandoc &>/dev/null; then
    skip "pandoc not installed"
  fi

  run bash "$SCRIPT_DIR/reports-combiner.sh"
  [[ "$status" -eq 0 ]]
  [[ -f "report_nested.html" ]]

  # The "Schema changes (direct)" h3 should be wrapped in a nested <details>
  # Check that there's a <details> with <summary> containing "Schema changes"
  grep -q '<summary>Schema changes' "report_nested.html"

  # Ensure nested details are inside the outer module details
  # (outer <details open> should appear before nested <details>)
  local outer_line nested_line
  outer_line=$(grep -n '<details open>' "report_nested.html" | head -1 | cut -d: -f1)
  nested_line=$(grep -n '<summary>Schema changes' "report_nested.html" | head -1 | cut -d: -f1)
  [[ "$nested_line" -gt "$outer_line" ]]
}

