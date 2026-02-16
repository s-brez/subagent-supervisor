#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SETUP_SCRIPT="${SCRIPT_DIR}/setup_demo_workspace.sh"
HARNESS_SCRIPT="${SCRIPT_DIR}/run_supervisor_loop.sh"
MODEL="${MODEL:-gpt-5.3-codex}"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "codex is required in PATH" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TMP_ROOT}"' EXIT

run_live_normal_path_test() {
  local ws="${TMP_ROOT}/ws-live-normal"
  "${SETUP_SCRIPT}" "${ws}" >/dev/null

  "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 4 \
    --model "${MODEL}" >/dev/null

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local last_signal
  local continue_count
  last_signal=$(tail -n 1 "${history}" | jq -r '.loop_signal')
  continue_count=$(jq -r 'select(.loop_signal == "CONTINUE") | .loop_signal' "${history}" | wc -l)

  [[ "${last_signal}" == "SHOULDNT_CONTINUE" ]]
  [[ "${continue_count}" -ge 1 ]]

  echo "PASS: live normal path reached CONTINUE and then SHOULDNT_CONTINUE"
}

run_live_max_loop_path_test() {
  local ws="${TMP_ROOT}/ws-live-max-loop"
  "${SETUP_SCRIPT}" "${ws}" >/dev/null

  cat >"${ws}/build_state.json" <<'JSON'
{ "current_phase": 2 }
JSON
  rm -rf "${ws}/output"
  mkdir -p "${ws}/output"

  set +e
  "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 2 \
    --model "${MODEL}" >/dev/null
  local rc=$?
  set -e

  [[ "${rc}" -eq 14 ]]

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local line_count
  line_count=$(wc -l <"${history}")
  [[ "${line_count}" -eq 2 ]]

  local s1 s2
  s1=$(sed -n '1p' "${history}" | jq -r '.loop_signal')
  s2=$(sed -n '2p' "${history}" | jq -r '.loop_signal')
  [[ "${s1}" == "CONTINUE" ]]
  [[ "${s2}" == "CONTINUE" ]]

  echo "PASS: live max-loop path hit repeated CONTINUE and exited with 14"
}

run_live_normal_path_test
run_live_max_loop_path_test

echo "All live e2e tests passed"
