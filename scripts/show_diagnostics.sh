#!/usr/bin/env bash
# Show failure diagnostics for a module compatibility run.
#
# Usage: scripts/show_diagnostics.sh <output-dir> <module-id> [context-label]
#
# Prints module-status.json, compatibility-summary.md, and the first 200 lines
# of compatibility-report.json, then exits non-zero.

set -euo pipefail

OUTPUT_DIR="${1:?Usage: show_diagnostics.sh <output-dir> <module-id> [context-label]}"
MODULE_ID="${2:?Usage: show_diagnostics.sh <output-dir> <module-id> [context-label]}"
CONTEXT="${3:-Runner}"

echo "${CONTEXT} failed for module: ${MODULE_ID}"

echo "---- module-status.json ----"
if [ -f "${OUTPUT_DIR}/module-status.json" ]; then
  cat "${OUTPUT_DIR}/module-status.json"
else
  echo "module-status file not found"
fi

echo "---- compatibility-summary.md ----"
if [ -f "${OUTPUT_DIR}/compatibility-summary.md" ]; then
  cat "${OUTPUT_DIR}/compatibility-summary.md"
else
  echo "summary file not found"
fi

echo "---- compatibility-report.json (first 200 lines) ----"
if [ -f "${OUTPUT_DIR}/compatibility-report.json" ]; then
  sed -n '1,200p' "${OUTPUT_DIR}/compatibility-report.json"
else
  echo "report file not found"
fi

exit 1
