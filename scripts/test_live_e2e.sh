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

assert_live_collab_lifecycle() {
  local ws="$1"
  local log
  local logs=("${ws}"/.orchestrator/logs/supervisor_iter_*.jsonl)

  [[ -e "${logs[0]}" ]]

  for log in "${logs[@]}"; do
    mapfile -t tools < <(
      jq -r '
        if (.type == "item.completed" and .item.type == "collab_tool_call")
        then .item.tool
        else empty
        end
      ' "${log}"
    )

    [[ "${#tools[@]}" -ge 1 ]]

    local spawn_idx=-1
    local close_idx=-1
    local i
    for i in "${!tools[@]}"; do
      if [[ "${tools[$i]}" == "spawn_agent" && "${spawn_idx}" -lt 0 ]]; then
        spawn_idx="${i}"
      fi
      if [[ "${tools[$i]}" == "close_agent" ]]; then
        close_idx="${i}"
      fi
    done

    [[ "${spawn_idx}" -ge 0 ]]
    [[ "${close_idx}" -ge 0 ]]
    [[ "${close_idx}" -gt "${spawn_idx}" ]]
  done
}

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
  assert_live_collab_lifecycle "${ws}"

  echo "PASS: live normal path reached CONTINUE -> SHOULDNT_CONTINUE and used spawn/close lifecycle"
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
  assert_live_collab_lifecycle "${ws}"

  echo "PASS: live max-loop path hit repeated CONTINUE, exited 14, and used spawn/close lifecycle"
}

run_live_normal_path_test
run_live_max_loop_path_test

echo "All live e2e tests passed"
