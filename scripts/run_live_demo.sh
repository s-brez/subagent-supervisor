#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
WORKSPACE="${1:-/tmp/codex-subagent-demo-live}"
MAX_LOOPS="${MAX_LOOPS:-6}"
MODEL="${MODEL:-gpt-5.3-codex}"

"${SCRIPT_DIR}/setup_demo_workspace.sh" "${WORKSPACE}"

"${SCRIPT_DIR}/run_supervisor_loop.sh" \
  --workspace "${WORKSPACE}" \
  --max-loops "${MAX_LOOPS}" \
  --model "${MODEL}"

echo "Live demo completed. Workspace: ${WORKSPACE}"
