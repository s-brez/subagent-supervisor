#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXAMPLE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
SETUP_SCRIPT="${SCRIPT_DIR}/setup_demo_workspace.sh"
HARNESS_SCRIPT="${SCRIPT_DIR}/run_supervisor_loop.sh"
FAKE_CODEX="${SCRIPT_DIR}/fake_codex.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

TMP_ROOT=$(mktemp -d)
trap 'rm -rf "${TMP_ROOT}"' EXIT

assert_exit_code() {
  local expected="$1"
  shift

  set +e
  "$@"
  local rc=$?
  set -e

  if [[ "${rc}" -ne "${expected}" ]]; then
    echo "Expected exit code ${expected}, got ${rc}" >&2
    return 1
  fi
}

setup_workspace() {
  local ws="$1"
  "${SETUP_SCRIPT}" "${ws}" >/dev/null
}

run_error_branch_tests() {
  local err_file

  err_file="${TMP_ROOT}/unknown-arg.err"
  assert_exit_code 2 "${HARNESS_SCRIPT}" --bad-flag >"${TMP_ROOT}/unknown-arg.out" 2>"${err_file}"
  grep -q "Unknown argument" "${err_file}"

  err_file="${TMP_ROOT}/workspace-missing.err"
  assert_exit_code 2 "${HARNESS_SCRIPT}" --workspace "${TMP_ROOT}/missing-workspace" >"${TMP_ROOT}/workspace-missing.out" 2>"${err_file}"
  grep -q "Workspace does not exist" "${err_file}"

  local no_jq_path="${TMP_ROOT}/no-jq-bin"
  mkdir -p "${no_jq_path}"
  ln -s "$(command -v dirname)" "${no_jq_path}/dirname"
  err_file="${TMP_ROOT}/jq-missing.err"
  assert_exit_code 2 env PATH="${no_jq_path}" /bin/bash "${HARNESS_SCRIPT}" --workspace "${TMP_ROOT}" >"${TMP_ROOT}/jq-missing.out" 2>"${err_file}"
  grep -q "jq is required" "${err_file}"

  local schema_copy_root="${TMP_ROOT}/schema-copy"
  cp -R "${EXAMPLE_DIR}" "${schema_copy_root}"
  rm -f "${schema_copy_root}/schemas/supervisor_output.schema.json"
  setup_workspace "${TMP_ROOT}/ws-schema-missing"
  err_file="${TMP_ROOT}/schema-missing.err"
  assert_exit_code 2 "${schema_copy_root}/scripts/run_supervisor_loop.sh" \
    --workspace "${TMP_ROOT}/ws-schema-missing" >"${TMP_ROOT}/schema-missing.out" 2>"${err_file}"
  grep -q "Schema not found" "${err_file}"

  local prompt_missing_copy_root="${TMP_ROOT}/prompt-missing-copy"
  cp -R "${EXAMPLE_DIR}" "${prompt_missing_copy_root}"
  rm -f "${prompt_missing_copy_root}/prompts/worker_review.md"
  setup_workspace "${TMP_ROOT}/ws-prompt-missing"
  err_file="${TMP_ROOT}/prompt-missing.err"
  assert_exit_code 2 "${prompt_missing_copy_root}/scripts/run_supervisor_loop.sh" \
    --workspace "${TMP_ROOT}/ws-prompt-missing" >"${TMP_ROOT}/prompt-missing.out" 2>"${err_file}"
  grep -q "Worker review prompt not found" "${err_file}"

  local prompt_empty_copy_root="${TMP_ROOT}/prompt-empty-copy"
  cp -R "${EXAMPLE_DIR}" "${prompt_empty_copy_root}"
  : >"${prompt_empty_copy_root}/prompts/worker_commit.md"
  setup_workspace "${TMP_ROOT}/ws-prompt-empty"
  err_file="${TMP_ROOT}/prompt-empty.err"
  assert_exit_code 2 "${prompt_empty_copy_root}/scripts/run_supervisor_loop.sh" \
    --workspace "${TMP_ROOT}/ws-prompt-empty" >"${TMP_ROOT}/prompt-empty.out" 2>"${err_file}"
  grep -q "Worker commit prompt is empty" "${err_file}"

  local task_spec_copy_root="${TMP_ROOT}/task-spec-missing-copy"
  cp -R "${EXAMPLE_DIR}" "${task_spec_copy_root}"
  rm -f "${task_spec_copy_root}/demo/task_spec.md"
  setup_workspace "${TMP_ROOT}/ws-task-spec-missing"
  err_file="${TMP_ROOT}/task-spec-missing.err"
  assert_exit_code 2 "${task_spec_copy_root}/scripts/run_supervisor_loop.sh" \
    --workspace "${TMP_ROOT}/ws-task-spec-missing" >"${TMP_ROOT}/task-spec-missing.out" 2>"${err_file}"
  grep -q "Task spec not found" "${err_file}"

  err_file="${TMP_ROOT}/history-metadata-invalid.err"
  setup_workspace "${TMP_ROOT}/ws-history-invalid"
  assert_exit_code 2 "${HARNESS_SCRIPT}" \
    --workspace "${TMP_ROOT}/ws-history-invalid" \
    --history-metadata-json '["not-an-object"]' >"${TMP_ROOT}/history-metadata-invalid.out" 2>"${err_file}"
  grep -q "history metadata must be a JSON object" "${err_file}"

  echo "PASS: harness preflight error branches (args, deps, files, prompt assets, metadata)"
}

run_main_path_test() {
  local ws="${TMP_ROOT}/ws-main"
  setup_workspace "${ws}"

  FAKE_CODEX_SEQUENCE="CONTINUE,CONTINUE,SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 8 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local count_file="${ws}/.orchestrator/state/fake_invocation_count.txt"

  [[ -f "${history}" ]]
  [[ -f "${count_file}" ]]

  local history_lines
  history_lines=$(wc -l <"${history}")
  [[ "${history_lines}" -eq 3 ]]

  local invocations
  invocations=$(cat "${count_file}")
  [[ "${invocations}" -eq 3 ]]

  local s1 s2 s3
  s1=$(sed -n '1p' "${history}" | jq -r '.loop_signal')
  s2=$(sed -n '2p' "${history}" | jq -r '.loop_signal')
  s3=$(sed -n '3p' "${history}" | jq -r '.loop_signal')

  [[ "${s1}" == "CONTINUE" ]]
  [[ "${s2}" == "CONTINUE" ]]
  [[ "${s3}" == "SHOULDNT_CONTINUE" ]]

  echo "PASS: main path hits CONTINUE and SHOULDNT_CONTINUE with restarts"
}

run_unknown_fallback_path_test() {
  local ws="${TMP_ROOT}/ws-unknown-fallback"
  setup_workspace "${ws}"

  FAKE_CODEX_SEQUENCE="UNKNOWN_CONTINUE,SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 8 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local s1 s2 r1
  s1=$(sed -n '1p' "${history}" | jq -r '.loop_signal')
  r1=$(sed -n '1p' "${history}" | jq -r '.review_outcome')
  s2=$(sed -n '2p' "${history}" | jq -r '.loop_signal')

  [[ "${s1}" == "CONTINUE" ]]
  [[ "${r1}" == "UNKNOWN" ]]
  [[ "${s2}" == "SHOULDNT_CONTINUE" ]]

  echo "PASS: fallback branch CONTINUE+UNKNOWN is accepted and loop still terminates"
}

run_restart_context_branch_test() {
  local ws="${TMP_ROOT}/ws-restart-context"
  setup_workspace "${ws}"

  FAKE_CODEX_SEQUENCE="CONTINUE,SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 8 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null

  local previous_output
  previous_output=$(jq -c . "${ws}/.orchestrator/state/last_supervisor_output.json")

  FAKE_CODEX_SEQUENCE="SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null

  local prompt_path="${ws}/.orchestrator/tmp/supervisor_prompt_iter_1.md"
  grep -Fq "${previous_output}" "${prompt_path}"

  echo "PASS: restart branch reuses prior supervisor output context"
}

run_restart_state_recovery_test() {
  local ws="${TMP_ROOT}/ws-restart-state-recovery"
  setup_workspace "${ws}"

  mkdir -p "${ws}/.orchestrator/state"
  printf '{broken json' >"${ws}/.orchestrator/state/last_supervisor_output.json"

  FAKE_CODEX_SEQUENCE="SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >"${TMP_ROOT}/restart-state-recovery.out" 2>"${TMP_ROOT}/restart-state-recovery.err"

  grep -q "using bootstrap context" "${TMP_ROOT}/restart-state-recovery.err"
  grep -Fq '"decision_reason":"bootstrap"' "${ws}/.orchestrator/tmp/supervisor_prompt_iter_1.md"

  local recovered_count
  recovered_count=$(find "${ws}/.orchestrator/state" -maxdepth 1 -name 'last_supervisor_output.json.invalid.*' | wc -l)
  [[ "${recovered_count}" -ge 1 ]]

  echo "PASS: invalid prior state is quarantined and bootstrap context is used"
}

run_runtime_failure_branch_tests() {
  local ws

  ws="${TMP_ROOT}/ws-codex-fail"
  setup_workspace "${ws}"
  assert_exit_code 10 env FAKE_CODEX_SEQUENCE="FAIL" "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>"${TMP_ROOT}/codex-fail.err"
  grep -q "Supervisor execution failed" "${TMP_ROOT}/codex-fail.err"

  ws="${TMP_ROOT}/ws-no-output"
  setup_workspace "${ws}"
  assert_exit_code 11 env FAKE_CODEX_SEQUENCE="NO_OUTPUT" "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>"${TMP_ROOT}/no-output.err"
  grep -q "Missing supervisor output file" "${TMP_ROOT}/no-output.err"

  ws="${TMP_ROOT}/ws-invalid-json"
  setup_workspace "${ws}"
  assert_exit_code 12 env FAKE_CODEX_SEQUENCE="INVALID_JSON" "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>"${TMP_ROOT}/invalid-json.err"
  grep -q "Supervisor output is not valid JSON" "${TMP_ROOT}/invalid-json.err"

  ws="${TMP_ROOT}/ws-invalid-shape"
  setup_workspace "${ws}"
  assert_exit_code 12 env FAKE_CODEX_SEQUENCE="INVALID_SHAPE" "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>"${TMP_ROOT}/invalid-shape.err"
  grep -q "does not match expected contract" "${TMP_ROOT}/invalid-shape.err"

  ws="${TMP_ROOT}/ws-invalid-signal"
  setup_workspace "${ws}"
  assert_exit_code 13 env FAKE_CODEX_SEQUENCE="INVALID_SIGNAL" "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>"${TMP_ROOT}/invalid-signal.err"
  grep -q "Invalid loop_signal" "${TMP_ROOT}/invalid-signal.err"

  echo "PASS: runtime failure branches (cmd fail, missing output, invalid json/shape, invalid signal)"
}

run_max_loop_guard_test() {
  local ws="${TMP_ROOT}/ws-max-loop"
  setup_workspace "${ws}"

  set +e
  FAKE_CODEX_SEQUENCE="CONTINUE,CONTINUE,CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 2 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" >/dev/null 2>&1
  local rc=$?
  set -e

  [[ "${rc}" -eq 14 ]]

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local history_lines
  history_lines=$(wc -l <"${history}")
  [[ "${history_lines}" -eq 2 ]]

  echo "PASS: max-loop guard stops endless CONTINUE runs"
}

run_fake_codex_script_branch_tests() {
  assert_exit_code 2 "${FAKE_CODEX}" >"${TMP_ROOT}/fake-missing-arg.out" 2>"${TMP_ROOT}/fake-missing-arg.err"
  grep -q "expected --output-last-message" "${TMP_ROOT}/fake-missing-arg.err"

  local ws="${TMP_ROOT}/ws-fake-script"
  mkdir -p "${ws}"
  local output_one="${TMP_ROOT}/fake-output-1.json"
  local output_two="${TMP_ROOT}/fake-output-2.json"

  FAKE_CODEX_SEQUENCE="CONTINUE" \
    "${FAKE_CODEX}" -C "${ws}" --output-last-message "${output_one}" >/dev/null
  "${FAKE_CODEX}" -C "${ws}" --output-last-message "${output_two}" >/dev/null

  local s1 s2
  s1=$(jq -r '.loop_signal' "${output_one}")
  s2=$(jq -r '.loop_signal' "${output_two}")
  [[ "${s1}" == "CONTINUE" ]]
  [[ "${s2}" == "SHOULDNT_CONTINUE" ]]

  echo "PASS: fake codex script branches (missing arg and empty-sequence fallback)"
}

run_history_metadata_extension_test() {
  local ws="${TMP_ROOT}/ws-history-metadata"
  setup_workspace "${ws}"

  FAKE_CODEX_SEQUENCE="SHOULDNT_CONTINUE" \
    "${HARNESS_SCRIPT}" \
    --workspace "${ws}" \
    --max-loops 1 \
    --codex-bin "${FAKE_CODEX}" \
    --model "fake-model" \
    --history-metadata-json '{"run_id":"deterministic-test","suite":"e2e"}' >/dev/null

  local history="${ws}/.orchestrator/state/supervisor_history.jsonl"
  local run_id
  run_id=$(sed -n '1p' "${history}" | jq -r '.history_metadata_extra.run_id')
  [[ "${run_id}" == "deterministic-test" ]]

  local prompt_path
  prompt_path=$(sed -n '1p' "${history}" | jq -r '.history_metadata.prompt_paths.worker_review')
  [[ "${prompt_path}" == */prompts/worker_review.md ]]

  echo "PASS: history metadata extension and prompt-path metadata recorded"
}

run_error_branch_tests
run_main_path_test
run_unknown_fallback_path_test
run_restart_context_branch_test
run_restart_state_recovery_test
run_runtime_failure_branch_tests
run_max_loop_guard_test
run_fake_codex_script_branch_tests
run_history_metadata_extension_test

echo "All e2e tests passed (including error and fallback branches)"
