#!/usr/bin/env bats
# Unit tests for helpers.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts/lib" && pwd)"

setup() {
  source "$SCRIPT_DIR/helpers.sh"
  TEST_TMP="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_TMP"
}

# ═══════════════════════════════════════════════════════════════════════════
# status_label
# ═══════════════════════════════════════════════════════════════════════════

@test "status_label: M → Modified" {
  result=$(status_label "M")
  [[ "$result" == "Modified" ]]
}

@test "status_label: A → Added" {
  result=$(status_label "A")
  [[ "$result" == "Added" ]]
}

@test "status_label: D → Deleted" {
  result=$(status_label "D")
  [[ "$result" == "Deleted" ]]
}

@test "status_label: R095 → Renamed (095%)" {
  result=$(status_label "R095")
  [[ "$result" == "Renamed (095%)" ]]
}

@test "status_label: R100 → Renamed (100%)" {
  result=$(status_label "R100")
  [[ "$result" == "Renamed (100%)" ]]
}

@test "status_label: C050 → Copied (050%)" {
  result=$(status_label "C050")
  [[ "$result" == "Copied (050%)" ]]
}

@test "status_label: T → Type changed" {
  result=$(status_label "T")
  [[ "$result" == "Type changed" ]]
}

@test "status_label: U → Unmerged" {
  result=$(status_label "U")
  [[ "$result" == "Unmerged" ]]
}

@test "status_label: unknown code passed through" {
  result=$(status_label "ZZ")
  [[ "$result" == "ZZ" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# truncate_or_all
# ═══════════════════════════════════════════════════════════════════════════

@test "truncate_or_all: small file returned in full" {
  printf '%s\n' "line1" "line2" "line3" > "$TEST_TMP/small.txt"
  result=$(truncate_or_all "$TEST_TMP/small.txt" 10)
  [[ "$result" == *"line1"* ]]
  [[ "$result" == *"line3"* ]]
  [[ "$result" != *"truncated"* ]]
}

@test "truncate_or_all: large file truncated with note" {
  seq 1 20 > "$TEST_TMP/large.txt"
  result=$(truncate_or_all "$TEST_TMP/large.txt" 5)
  # Should contain first 5 lines
  [[ "$result" == *"5"* ]]
  # Should NOT contain line 6+
  [[ "$result" != *"6"$'\n'* ]]
  # Should have truncation message
  [[ "$result" == *"truncated to 5 lines"* ]]
}

@test "truncate_or_all: empty file" {
  : > "$TEST_TMP/empty.txt"
  result=$(truncate_or_all "$TEST_TMP/empty.txt" 10)
  [[ -z "$result" ]]
}

@test "truncate_or_all: exact boundary (lines == max)" {
  seq 1 5 > "$TEST_TMP/exact.txt"
  result=$(truncate_or_all "$TEST_TMP/exact.txt" 5)
  [[ "$result" == *"5"* ]]
  [[ "$result" != *"truncated"* ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# resolve_path
# ═══════════════════════════════════════════════════════════════════════════

@test "resolve_path: simple join" {
  result=$(resolve_path "ramls" "acq-models/mod-orgs/schemas/org.json")
  [[ "$result" == "ramls/acq-models/mod-orgs/schemas/org.json" ]]
}

@test "resolve_path: relative with .." {
  result=$(resolve_path "ramls/acq-models/mod-orgs/schemas" "../../common/schemas/uuid.json")
  [[ "$result" == "ramls/acq-models/common/schemas/uuid.json" ]]
}

@test "resolve_path: relative with ./ prefix" {
  result=$(resolve_path "ramls/schemas" "./types/item.json")
  [[ "$result" == "ramls/schemas/types/item.json" ]]
}

@test "resolve_path: already normalized" {
  result=$(resolve_path "." "ramls/schema.json")
  [[ "$result" == "ramls/schema.json" ]]
}

@test "resolve_path: complex relative traversal" {
  result=$(resolve_path "ramls/acq-models/mod-orders-storage/schemas" "../../../raml-util/schemas/metadata.json")
  [[ "$result" == "ramls/raml-util/schemas/metadata.json" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# extract_json_refs
# ═══════════════════════════════════════════════════════════════════════════

@test "extract_json_refs: extracts \$ref from simple schema" {
  local JSON='{
    "properties": {
      "id": { "$ref": "common/uuid.json" },
      "name": { "type": "string" }
    }
  }'
  result=$(extract_json_refs "$JSON")
  [[ "$result" == "common/uuid.json" ]]
}

@test "extract_json_refs: extracts multiple refs" {
  local JSON='{
    "properties": {
      "id": { "$ref": "common/uuid.json" },
      "meta": { "$ref": "common/metadata.json#/properties" }
    }
  }'
  result=$(extract_json_refs "$JSON")
  [[ "$result" == *"common/uuid.json"* ]]
  [[ "$result" == *"common/metadata.json"* ]]
}

@test "extract_json_refs: strips fragment from \$ref" {
  local JSON='{ "allOf": [{ "$ref": "base.json#/definitions/thing" }] }'
  result=$(extract_json_refs "$JSON")
  [[ "$result" == "base.json" ]]
}

@test "extract_json_refs: ignores non-json refs" {
  local JSON='{ "$ref": "#/definitions/local" }'
  result=$(extract_json_refs "$JSON")
  [[ -z "$result" ]]
}

@test "extract_json_refs: nested refs in arrays" {
  local JSON='{
    "items": {
      "anyOf": [
        { "$ref": "type_a.json" },
        { "$ref": "type_b.json" }
      ]
    }
  }'
  result=$(extract_json_refs "$JSON")
  [[ "$result" == *"type_a.json"* ]]
  [[ "$result" == *"type_b.json"* ]]
}

@test "extract_json_refs: empty/invalid JSON returns empty" {
  result=$(extract_json_refs "not valid json")
  [[ -z "$result" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# extract_raml_includes
# ═══════════════════════════════════════════════════════════════════════════

@test "extract_raml_includes: standard include" {
  local RAML='  type: !include acq-models/mod-orgs/schemas/organization.json'
  result=$(extract_raml_includes "$RAML")
  [[ "$result" == "acq-models/mod-orgs/schemas/organization.json" ]]
}

@test "extract_raml_includes: multiple includes" {
  local RAML='  org: !include acq-models/mod-orgs/schemas/org.json
  addr: !include acq-models/mod-orgs/schemas/address.json'
  result=$(extract_raml_includes "$RAML")
  [[ "$result" == *"org.json"* ]]
  [[ "$result" == *"address.json"* ]]
}

@test "extract_raml_includes: ignores non-json includes" {
  local RAML='  traits: !include raml-util/traits/validation.raml
  example: !include examples/org.sample'
  result=$(extract_raml_includes "$RAML")
  [[ -z "$result" ]]
}

@test "extract_raml_includes: multiple spaces after !include" {
  local RAML='  schema: !include   acq-models/common/schemas/uuid.json'
  result=$(extract_raml_includes "$RAML")
  [[ "$result" == "acq-models/common/schemas/uuid.json" ]]
}

@test "extract_raml_includes: tab after !include" {
  printf '  schema: !include\tacq-models/schema.json\n' > "$TEST_TMP/raml.txt"
  result=$(extract_raml_includes "$(cat "$TEST_TMP/raml.txt")")
  [[ "$result" == "acq-models/schema.json" ]]
}

@test "extract_raml_includes: deduplicates" {
  local RAML='  a: !include common/uuid.json
  b: !include common/uuid.json'
  result=$(extract_raml_includes "$RAML")
  local count
  count=$(echo "$result" | wc -l | tr -d ' ')
  [[ "$count" == "1" ]]
}

# ═══════════════════════════════════════════════════════════════════════════
# is_path_in_submodule / strip_sm_prefix
# ═══════════════════════════════════════════════════════════════════════════

@test "is_path_in_submodule: matching path" {
  is_path_in_submodule "ramls/acq-models/mod-orgs/schemas/org.json" "ramls/acq-models"
}

@test "is_path_in_submodule: non-matching path" {
  ! is_path_in_submodule "ramls/schemas/org.json" "ramls/acq-models"
}

@test "is_path_in_submodule: partial prefix not matching" {
  # "ramls/acq-models-extra/foo" should NOT match "ramls/acq-models"
  ! is_path_in_submodule "ramls/acq-models-extra/foo.json" "ramls/acq-models"
}

@test "strip_sm_prefix: strips correctly" {
  result=$(strip_sm_prefix "ramls/acq-models/mod-orgs/schemas/org.json" "ramls/acq-models")
  [[ "$result" == "mod-orgs/schemas/org.json" ]]
}

@test "strip_sm_prefix: single level" {
  result=$(strip_sm_prefix "ramls/raml-storage/schemas/dto/record.json" "ramls/raml-storage")
  [[ "$result" == "schemas/dto/record.json" ]]
}

