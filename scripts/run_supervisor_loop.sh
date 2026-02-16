#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
EXAMPLE_DIR=$(cd -- "${SCRIPT_DIR}/.." && pwd)
PROMPTS_DIR="${EXAMPLE_DIR}/prompts"
SCHEMA_PATH="${EXAMPLE_DIR}/schemas/supervisor_output.schema.json"
TASK_SPEC_PATH="${EXAMPLE_DIR}/demo/task_spec.md"

WORKSPACE="$(pwd)"
MAX_LOOPS=8
MODEL="gpt-5.3-codex"
CODEX_BIN="codex"

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

if [[ ! -f "${SCHEMA_PATH}" ]]; then
  echo "Schema not found: ${SCHEMA_PATH}" >&2
  exit 2
fi

STATE_ROOT="${WORKSPACE}/.orchestrator"
LOG_DIR="${STATE_ROOT}/logs"
TMP_DIR="${STATE_ROOT}/tmp"
STATE_DIR="${STATE_ROOT}/state"
HISTORY_PATH="${STATE_DIR}/supervisor_history.jsonl"
LAST_OUTPUT_PATH="${STATE_DIR}/last_supervisor_output.json"

mkdir -p "${LOG_DIR}" "${TMP_DIR}" "${STATE_DIR}" "${WORKSPACE}/.orchestrator_assets"
cp "${TASK_SPEC_PATH}" "${WORKSPACE}/.orchestrator_assets/task_spec.md"

if [[ -f "${LAST_OUTPUT_PATH}" ]]; then
  PREV_OUTPUT_JSON=$(jq -c . "${LAST_OUTPUT_PATH}")
else
  PREV_OUTPUT_JSON='{"loop_signal":"CONTINUE","decision_reason":"bootstrap","iteration_summary":"first run","review_outcome":"UNKNOWN","worker_id":"","commit_status":"UNKNOWN","commit_sha":""}'
fi

render_prompt() {
  local iteration="$1"
  local previous_json="$2"
  local prompt_file="$3"

  awk \
    -v iteration="${iteration}" \
    -v workspace="${WORKSPACE}" \
    -v previous_json="${previous_json}" \
    -v review_file="${PROMPTS_DIR}/worker_review.md" \
    -v implement_file="${PROMPTS_DIR}/worker_implement.md" \
    -v commit_file="${PROMPTS_DIR}/worker_commit.md" \
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
    ' "${PROMPTS_DIR}/supervisor.md" >"${prompt_file}"
}

ITER=1
while (( ITER <= MAX_LOOPS )); do
  PROMPT_FILE="${TMP_DIR}/supervisor_prompt_iter_${ITER}.md"
  OUTPUT_FILE="${STATE_DIR}/supervisor_output_iter_${ITER}.json"
  JSONL_LOG="${LOG_DIR}/supervisor_iter_${ITER}.jsonl"
  STDERR_LOG="${LOG_DIR}/supervisor_iter_${ITER}.stderr.log"

  render_prompt "${ITER}" "${PREV_OUTPUT_JSON}" "${PROMPT_FILE}"

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

  cp "${OUTPUT_FILE}" "${LAST_OUTPUT_PATH}"
  PREV_OUTPUT_JSON=$(jq -c . "${OUTPUT_FILE}")
  jq -c --argjson iteration "${ITER}" '. + {iteration: $iteration}' "${OUTPUT_FILE}" >>"${HISTORY_PATH}"

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
