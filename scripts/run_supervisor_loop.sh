#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXAMPLE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)

PROMPTS_DIR="${EXAMPLE_DIR}/prompts"
SUPERVISOR_PROMPT_PATH="${PROMPTS_DIR}/supervisor.md"
WORKER_REVIEW_PROMPT_PATH="${PROMPTS_DIR}/worker_review.md"
WORKER_IMPLEMENT_PROMPT_PATH="${PROMPTS_DIR}/worker_implement.md"
WORKER_COMMIT_PROMPT_PATH="${PROMPTS_DIR}/worker_commit.md"
SCHEMA_PATH="${EXAMPLE_DIR}/schemas/supervisor_output.schema.json"
TASK_SPEC_PATH="${EXAMPLE_DIR}/demo/task_spec.md"

WORKSPACE="$(pwd)"
MAX_LOOPS=8
MODEL="gpt-5.3-codex"
CODEX_BIN="codex"
HISTORY_METADATA_JSON='{}'

BOOTSTRAP_OUTPUT_JSON='{"loop_signal":"CONTINUE","decision_reason":"bootstrap","iteration_summary":"first run","review_outcome":"UNKNOWN","worker_id":"","commit_status":"UNKNOWN","commit_sha":""}'

print_usage() {
  cat <<'USAGE'
Usage: run_supervisor_loop.sh [options]

Options:
  --workspace PATH
  --max-loops N
  --model NAME
  --codex-bin PATH
  --prompts-dir PATH
  --supervisor-prompt PATH
  --worker-review-prompt PATH
  --worker-implement-prompt PATH
  --worker-commit-prompt PATH
  --schema-path PATH
  --task-spec-path PATH
  --history-metadata-json JSON_OBJECT
  --history-metadata-file PATH
  --help
USAGE
}

require_nonempty_file() {
  local path="$1"
  local label="$2"

  if [[ ! -f "${path}" ]]; then
    echo "${label} not found: ${path}" >&2
    exit 2
  fi

  if [[ ! -s "${path}" ]]; then
    echo "${label} is empty: ${path}" >&2
    exit 2
  fi
}

validate_supervisor_output_contract() {
  local output_path="$1"

  jq -e '
    type == "object" and
    (
      (keys | sort) ==
      ["commit_sha","commit_status","decision_reason","iteration_summary","loop_signal","review_outcome","worker_id"]
    ) and
    (.loop_signal | type == "string") and
    (.decision_reason | type == "string") and
    (.iteration_summary | type == "string") and
    (.review_outcome == "DONE" or .review_outcome == "NOT_DONE" or .review_outcome == "UNKNOWN") and
    (.worker_id | type == "string") and
    (.commit_status == "COMMITTED" or .commit_status == "NO_CHANGES" or .commit_status == "SKIPPED" or .commit_status == "UNKNOWN") and
    (.commit_sha | type == "string")
  ' "${output_path}" >/dev/null
}

append_history_record() {
  local iteration="$1"
  local output_path="$2"
  local timestamp_utc
  timestamp_utc=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  jq -c \
    --argjson iteration "${iteration}" \
    --arg timestamp_utc "${timestamp_utc}" \
    --arg workspace "${WORKSPACE}" \
    --arg model "${MODEL}" \
    --arg schema_path "${SCHEMA_PATH}" \
    --arg task_spec_path "${TASK_SPEC_PATH}" \
    --arg supervisor_prompt_path "${SUPERVISOR_PROMPT_PATH}" \
    --arg worker_review_prompt_path "${WORKER_REVIEW_PROMPT_PATH}" \
    --arg worker_implement_prompt_path "${WORKER_IMPLEMENT_PROMPT_PATH}" \
    --arg worker_commit_prompt_path "${WORKER_COMMIT_PROMPT_PATH}" \
    --argjson history_extra "${HISTORY_METADATA_JSON}" \
    '
      . + {
        iteration: $iteration,
        history_metadata: {
          timestamp_utc: $timestamp_utc,
          workspace: $workspace,
          model: $model,
          schema_path: $schema_path,
          task_spec_path: $task_spec_path,
          prompt_paths: {
            supervisor: $supervisor_prompt_path,
            worker_review: $worker_review_prompt_path,
            worker_implement: $worker_implement_prompt_path,
            worker_commit: $worker_commit_prompt_path
          }
        }
      } +
      (if ($history_extra | length) > 0 then {history_metadata_extra: $history_extra} else {} end)
    ' "${output_path}" >>"${HISTORY_PATH}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --workspace)
      WORKSPACE="$2"
      shift 2
      ;;
    --max-loops)
      MAX_LOOPS="$2"
      shift 2
      ;;
    --model)
      MODEL="$2"
      shift 2
      ;;
    --codex-bin)
      CODEX_BIN="$2"
      shift 2
      ;;
    --prompts-dir)
      PROMPTS_DIR="$2"
      SUPERVISOR_PROMPT_PATH="${PROMPTS_DIR}/supervisor.md"
      WORKER_REVIEW_PROMPT_PATH="${PROMPTS_DIR}/worker_review.md"
      WORKER_IMPLEMENT_PROMPT_PATH="${PROMPTS_DIR}/worker_implement.md"
      WORKER_COMMIT_PROMPT_PATH="${PROMPTS_DIR}/worker_commit.md"
      shift 2
      ;;
    --supervisor-prompt)
      SUPERVISOR_PROMPT_PATH="$2"
      shift 2
      ;;
    --worker-review-prompt)
      WORKER_REVIEW_PROMPT_PATH="$2"
      shift 2
      ;;
    --worker-implement-prompt)
      WORKER_IMPLEMENT_PROMPT_PATH="$2"
      shift 2
      ;;
    --worker-commit-prompt)
      WORKER_COMMIT_PROMPT_PATH="$2"
      shift 2
      ;;
    --schema-path)
      SCHEMA_PATH="$2"
      shift 2
      ;;
    --task-spec-path)
      TASK_SPEC_PATH="$2"
      shift 2
      ;;
    --history-metadata-json)
      HISTORY_METADATA_JSON="$2"
      shift 2
      ;;
    --history-metadata-file)
      HISTORY_METADATA_JSON=$(cat "$2")
      shift 2
      ;;
    --help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 2
fi

if [[ ! -d "${WORKSPACE}" ]]; then
  echo "Workspace does not exist: ${WORKSPACE}" >&2
  exit 2
fi

if ! jq -e 'type == "object"' <<<"${HISTORY_METADATA_JSON}" >/dev/null; then
  echo "history metadata must be a JSON object" >&2
  exit 2
fi

require_nonempty_file "${SCHEMA_PATH}" "Schema"
require_nonempty_file "${TASK_SPEC_PATH}" "Task spec"
require_nonempty_file "${SUPERVISOR_PROMPT_PATH}" "Supervisor prompt"
require_nonempty_file "${WORKER_REVIEW_PROMPT_PATH}" "Worker review prompt"
require_nonempty_file "${WORKER_IMPLEMENT_PROMPT_PATH}" "Worker implement prompt"
require_nonempty_file "${WORKER_COMMIT_PROMPT_PATH}" "Worker commit prompt"

STATE_ROOT="${WORKSPACE}/.orchestrator"
LOG_DIR="${STATE_ROOT}/logs"
TMP_DIR="${STATE_ROOT}/tmp"
STATE_DIR="${STATE_ROOT}/state"
HISTORY_PATH="${STATE_DIR}/supervisor_history.jsonl"
LAST_OUTPUT_PATH="${STATE_DIR}/last_supervisor_output.json"

mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${STATE_DIR}" "${WORKSPACE}/.orchestrator_assets"
cp "${TASK_SPEC_PATH}" "${WORKSPACE}/.orchestrator_assets/task_spec.md"

if [[ -f "${LAST_OUTPUT_PATH}" ]]; then
  if PREV_OUTPUT_JSON=$(jq -ce 'if type == "object" then . else error("not object") end' "${LAST_OUTPUT_PATH}" 2>/dev/null); then
    :
  else
    INVALID_LAST_OUTPUT_PATH="${LAST_OUTPUT_PATH}.invalid.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "${LAST_OUTPUT_PATH}" "${INVALID_LAST_OUTPUT_PATH}"
    echo "Warning: invalid previous supervisor output JSON moved to ${INVALID_LAST_OUTPUT_PATH}; using bootstrap context" >&2
    PREV_OUTPUT_JSON="${BOOTSTRAP_OUTPUT_JSON}"
  fi
else
  PREV_OUTPUT_JSON="${BOOTSTRAP_OUTPUT_JSON}"
fi

render_prompt() {
  local iteration="$1"
  local previous_json="$2"
  local prompt_file="$3"
  local supervisor_prompt_file="$4"

  awk \
    -v iteration="${iteration}" \
    -v workspace="${WORKSPACE}" \
    -v previous_json="${previous_json}" \
    -v review_file="${WORKER_REVIEW_PROMPT_PATH}" \
    -v implement_file="${WORKER_IMPLEMENT_PROMPT_PATH}" \
    -v commit_file="${WORKER_COMMIT_PROMPT_PATH}" \
    '
      function slurp(path,    line, text) {
        text = ""
        while ((getline line < path) > 0) {
          text = text line "\n"
        }
        close(path)
        return text
      }
      function replace_token(src, token, repl,    pos) {
        pos = index(src, token)
        if (pos == 0) {
          return src
        }
        return substr(src, 1, pos - 1) repl substr(src, pos + length(token))
      }
      BEGIN {
        review_prompt = slurp(review_file)
        implement_prompt = slurp(implement_file)
        commit_prompt = slurp(commit_file)
      }
      {
        line = $0
        line = replace_token(line, "__ITERATION__", iteration)
        line = replace_token(line, "__WORKSPACE__", workspace)
        line = replace_token(line, "__PREVIOUS_OUTPUT_JSON__", previous_json)

        if (line == "__WORKER_REVIEW_PROMPT__") {
          printf "%s", review_prompt
          next
        }
        if (line == "__WORKER_IMPLEMENT_PROMPT__") {
          printf "%s", implement_prompt
          next
        }
        if (line == "__WORKER_COMMIT_PROMPT__") {
          printf "%s", commit_prompt
          next
        }

        print line
      }
    ' "${supervisor_prompt_file}" >"${prompt_file}"
}

ITER=1
while (( ITER <= MAX_LOOPS )); do
  PROMPT_FILE="${TMP_DIR}/supervisor_prompt_iter_${ITER}.md"
  OUTPUT_FILE="${STATE_DIR}/supervisor_output_iter_${ITER}.json"
  JSONL_LOG="${LOG_DIR}/supervisor_iter_${ITER}.jsonl"
  STDERR_LOG="${LOG_DIR}/supervisor_iter_${ITER}.stderr.log"

  render_prompt "${ITER}" "${PREV_OUTPUT_JSON}" "${PROMPT_FILE}" "${SUPERVISOR_PROMPT_PATH}"

  echo "[loop] iteration ${ITER}/${MAX_LOOPS}"

  PROMPT_TEXT=$(cat "${PROMPT_FILE}")
  CMD=(
    "${CODEX_BIN}"
    "--enable" "collab"
    "exec"
    "--skip-git-repo-check"
    "--sandbox" "workspace-write"
    "-C" "${WORKSPACE}"
    "--model" "${MODEL}"
    "--output-schema" "${SCHEMA_PATH}"
    "--output-last-message" "${OUTPUT_FILE}"
    "--json"
    "${PROMPT_TEXT}"
  )

  if ! "${CMD[@]}" >"${JSONL_LOG}" 2>"${STDERR_LOG}"; then
    echo "Supervisor execution failed on iteration ${ITER}. See ${STDERR_LOG}" >&2
    exit 10
  fi

  if [[ ! -f "${OUTPUT_FILE}" ]]; then
    echo "Missing supervisor output file: ${OUTPUT_FILE}" >&2
    exit 11
  fi

  if ! jq -e . "${OUTPUT_FILE}" >/dev/null; then
    echo "Supervisor output is not valid JSON: ${OUTPUT_FILE}" >&2
    exit 12
  fi

  if ! validate_supervisor_output_contract "${OUTPUT_FILE}"; then
    echo "Supervisor output does not match expected contract: ${OUTPUT_FILE}" >&2
    exit 12
  fi

  cp "${OUTPUT_FILE}" "${LAST_OUTPUT_PATH}"
  PREV_OUTPUT_JSON=$(jq -c . "${OUTPUT_FILE}")
  append_history_record "${ITER}" "${OUTPUT_FILE}"

  LOOP_SIGNAL=$(jq -r '.loop_signal' "${OUTPUT_FILE}")
  echo "[loop] signal=${LOOP_SIGNAL}"

  case "${LOOP_SIGNAL}" in
    SHOULDNT_CONTINUE)
      echo "[loop] finished on iteration ${ITER}"
      exit 0
      ;;
    CONTINUE)
      ((ITER += 1))
      ;;
    *)
      echo "Invalid loop_signal '${LOOP_SIGNAL}' in ${OUTPUT_FILE}" >&2
      exit 13
      ;;
  esac
done

echo "Reached max loops (${MAX_LOOPS}) without SHOULDNT_CONTINUE" >&2
exit 14
