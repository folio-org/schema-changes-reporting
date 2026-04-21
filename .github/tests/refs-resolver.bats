#!/usr/bin/env bats
# Unit tests for refs-resolver.sh

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")/../scripts" && pwd)"

setup() {
  TEST_TMP="$(mktemp -d)"
  export GITHUB_OUTPUT="$TEST_TMP/github_output"
  : > "$GITHUB_OUTPUT"

  # Create a test git repo
  export TEST_REPO="$TEST_TMP/repo"
  git init -q "$TEST_REPO"
  cd "$TEST_REPO"
  git commit --allow-empty -m "root" -q
  ROOT_SHA=$(git rev-parse HEAD)
  git commit --allow-empty -m "second" -q
  SECOND_SHA=$(git rev-parse HEAD)
  git tag v1.0.0
  git commit --allow-empty -m "third" -q
  THIRD_SHA=$(git rev-parse HEAD)
  git tag v2.0.0
  export GITHUB_SHA="$THIRD_SHA"
}

teardown() {
  rm -rf "$TEST_TMP"
}

run_resolve_refs() {
  cd "$TEST_REPO"
  bash "$SCRIPT_DIR/refs-resolver.sh"
}

@test "resolve-refs: push event uses BEFORE_SHA and GITHUB_SHA" {
  export EVENT_NAME="push"
  export BEFORE_SHA="$SECOND_SHA"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "base=$SECOND_SHA" "$GITHUB_OUTPUT"
  grep -q "head=$THIRD_SHA" "$GITHUB_OUTPUT"
}

@test "resolve-refs: push event with all-zero BEFORE falls back to HEAD~1" {
  export EVENT_NAME="push"
  export BEFORE_SHA="0000000000000000000000000000000000000000"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "base=$SECOND_SHA" "$GITHUB_OUTPUT"
}

@test "resolve-refs: pull_request event uses PR SHAs" {
  export EVENT_NAME="pull_request"
  export PR_BASE_SHA="$SECOND_SHA"
  export PR_HEAD_SHA="$THIRD_SHA"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "base=$SECOND_SHA" "$GITHUB_OUTPUT"
  grep -q "head=$THIRD_SHA" "$GITHUB_OUTPUT"
}

@test "resolve-refs: release event finds previous tag" {
  export EVENT_NAME="release"
  export RELEASE_TAG="v2.0.0"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "head=.*" "$GITHUB_OUTPUT"
  # BASE should be v1.0.0
  local base_val
  base_val=$(grep "^base=" "$GITHUB_OUTPUT" | cut -d= -f2)
  # Resolve v1.0.0 to SHA and compare
  local v1_sha
  v1_sha=$(cd "$TEST_REPO" && git rev-parse v1.0.0)
  [[ "$base_val" == "$v1_sha" || "$base_val" == "v1.0.0" ]]
}

@test "resolve-refs: workflow_dispatch with no inputs uses latest two tags" {
  export EVENT_NAME="workflow_dispatch"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "base=" "$GITHUB_OUTPUT"
  grep -q "head=" "$GITHUB_OUTPUT"
}

@test "resolve-refs: workflow_dispatch with explicit inputs" {
  export EVENT_NAME="workflow_dispatch"
  export INPUT_BASE="$SECOND_SHA"
  export INPUT_HEAD="$THIRD_SHA"
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "base=$SECOND_SHA" "$GITHUB_OUTPUT"
  grep -q "head=$THIRD_SHA" "$GITHUB_OUTPUT"
}

@test "resolve-refs: invalid ref fails with error" {
  export EVENT_NAME="push"
  export BEFORE_SHA="$SECOND_SHA"
  export INPUT_BASE="" INPUT_HEAD="nonexistent_ref_xyz"
  run run_resolve_refs
  [[ "$status" -ne 0 ]]
}

@test "resolve-refs: unknown event uses GITHUB_SHA" {
  export EVENT_NAME="schedule"
  export INPUT_BASE="" INPUT_HEAD=""
  run run_resolve_refs
  [[ "$status" -eq 0 ]]
  grep -q "head=$THIRD_SHA" "$GITHUB_OUTPUT"
}

