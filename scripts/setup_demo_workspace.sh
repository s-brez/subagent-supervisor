#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXAMPLE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
WORKSPACE="${1:-/tmp/codex-subagent-demo}"

rm -rf "${WORKSPACE}"
mkdir -p "${WORKSPACE}/output" "${WORKSPACE}/.orchestrator_assets"

cat > "${WORKSPACE}/build_state.json" <<'JSON'
{ "current_phase": 0 }
JSON

cp "${EXAMPLE_DIR}/demo/task_spec.md" "${WORKSPACE}/.orchestrator_assets/task_spec.md"

cat > "${WORKSPACE}/README.md" <<'EOF_README'
# Toy Build Workspace

This repository is used by the subagent supervisor loop demo.
EOF_README

(
  cd "${WORKSPACE}"
  git init -q
  git config user.name "Codex Demo"
  git config user.email "codex-demo@example.com"
  git add README.md build_state.json .orchestrator_assets/task_spec.md
  git commit -q -m "demo: initial state"
)

echo "Workspace ready: ${WORKSPACE}"
