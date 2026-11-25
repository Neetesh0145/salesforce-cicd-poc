#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# Computes the Salesforce metadata delta between two git refs (sfdx-git-delta)
# and either validates it (dry run, nothing is saved in the org) or deploys it.
#
# Usage:
#   sf-delta-deploy.sh <validate|deploy> <org-alias> <from-ref> [to-ref]
#
# Environment variables:
#   TEST_LEVEL       NoTestRun | RunSpecifiedTests | RunLocalTests | RunAllTestsInOrg
#                    (default RunLocalTests; NoTestRun is only allowed in sandboxes)
#   SPECIFIED_TESTS  Comma-separated test classes, required with RunSpecifiedTests
#   SOURCE_DIR       Folder to diff (default force-app)
#   DELTA_DIR        Output folder for the generated manifests (default .delta)
# -----------------------------------------------------------------------------
set -euo pipefail

MODE="${1:?mode is required: validate or deploy}"
ORG="${2:?org alias is required}"
FROM="${3:?from-ref is required}"
TO="${4:-HEAD}"
TEST_LEVEL="${TEST_LEVEL:-RunLocalTests}"
SOURCE_DIR="${SOURCE_DIR:-force-app}"
DELTA_DIR="${DELTA_DIR:-.delta}"

case "$MODE" in
  validate|deploy) ;;
  *) echo "::error::Unknown mode '$MODE' (expected validate or deploy)"; exit 2 ;;
esac

summary() {
  if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
    echo "$1" >> "$GITHUB_STEP_SUMMARY"
  fi
}

has_types() {
  [[ -f "$1" ]] && grep -q "<types>" "$1"
}

echo "Computing delta: $FROM -> $TO (source: $SOURCE_DIR)"
rm -rf "$DELTA_DIR"
mkdir -p "$DELTA_DIR"
sf sgd source delta \
  --from "$FROM" \
  --to "$TO" \
  --source-dir "$SOURCE_DIR" \
  --output-dir "$DELTA_DIR"

PACKAGE_XML="$DELTA_DIR/package/package.xml"
DESTRUCTIVE_XML="$DELTA_DIR/destructiveChanges/destructiveChanges.xml"

if ! has_types "$PACKAGE_XML" && ! has_types "$DESTRUCTIVE_XML"; then
  echo "No Salesforce metadata changes between $FROM and $TO - nothing to $MODE."
  summary "### No metadata changes - nothing to $MODE"
  exit 0
fi

echo "----- package.xml (added / changed) -----"
cat "$PACKAGE_XML"
summary "### Metadata to $MODE"
summary '```xml'
summary "$(cat "$PACKAGE_XML")"
summary '```'

ARGS=(
  --manifest "$PACKAGE_XML"
  --target-org "$ORG"
  --test-level "$TEST_LEVEL"
  --wait 120
  --verbose
)

if has_types "$DESTRUCTIVE_XML"; then
  echo "----- destructiveChanges.xml (deleted) -----"
  cat "$DESTRUCTIVE_XML"
  summary "### Metadata to delete"
  summary '```xml'
  summary "$(cat "$DESTRUCTIVE_XML")"
  summary '```'
  ARGS+=(--post-destructive-changes "$DESTRUCTIVE_XML")
fi

if [[ "$TEST_LEVEL" == "RunSpecifiedTests" ]]; then
  if [[ -z "${SPECIFIED_TESTS:-}" ]]; then
    echo "::error::TEST_LEVEL is RunSpecifiedTests but SPECIFIED_TESTS is empty"
    exit 2
  fi
  IFS=',' read -ra TESTS <<< "$SPECIFIED_TESTS"
  for t in "${TESTS[@]}"; do
    t="$(echo "$t" | xargs)"
    if [[ -n "$t" ]]; then
      ARGS+=(--tests "$t")
    fi
  done
fi

if [[ "$MODE" == "validate" ]]; then
  ARGS+=(--dry-run)
fi

echo "Running: sf project deploy start ${ARGS[*]}"
sf project deploy start "${ARGS[@]}"

summary "**Result:** $MODE succeeded on \`$ORG\` with test level \`$TEST_LEVEL\`."
