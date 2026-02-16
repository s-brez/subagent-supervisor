#!/usr/bin/env bash
set -euo pipefail

WORKSPACE="$(pwd)"
OUTPUT_FILE=""

ARGS=("$@")
IDX=0
while (( IDX < ${#ARGS[@]} )); do
  case "${ARGS[$IDX]}" in
    -C|--cd)
      IDX=$((IDX + 1))
      WORKSPACE="${ARGS[$IDX]}"
      ;;
    --output-last-message)
      IDX=$((IDX + 1))
      OUTPUT_FILE="${ARGS[$IDX]}"
      ;;
  esac
  IDX=$((IDX + 1))
done

if [[ -z "${OUTPUT_FILE}" ]]; then
  echo "fake_codex.sh expected --output-last-message" >&2
  exit 2
fi

STATE_ROOT="${WORKSPACE}/.orchestrator"
mkdir -p "${STATE_ROOT}/state"
SEQUENCE_FILE="${STATE_ROOT}/state/fake_sequence_state.txt"
COUNT_FILE="${STATE_ROOT}/state/fake_invocation_count.txt"

if [[ ! -f "${SEQUENCE_FILE}" ]]; then
  echo "${FAKE_CODEX_SEQUENCE:-CONTINUE,CONTINUE,SHOULDNT_CONTINUE}" >"${SEQUENCE_FILE}"
fi

if [[ ! -f "${COUNT_FILE}" ]]; then
  echo "0" >"${COUNT_FILE}"
fi

COUNT=$(cat "${COUNT_FILE}")
COUNT=$((COUNT + 1))
echo "${COUNT}" >"${COUNT_FILE}"

SEQUENCE=$(cat "${SEQUENCE_FILE}")
FIRST="${SEQUENCE%%,*}"
if [[ "${SEQUENCE}" == *","* ]]; then
  REST="${SEQUENCE#*,}"
else
  REST=""
fi
echo "${REST}" >"${SEQUENCE_FILE}"

if [[ -z "${FIRST}" ]]; then
  FIRST="SHOULDNT_CONTINUE"
fi

emit_jsonl() {
  printf '{"type":"thread.started","thread_id":"fake-thread"}\n'
  printf '{"type":"turn.completed","usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":1}}\n'
}

case "${FIRST}" in
  FAIL)
    echo "fake_codex requested to fail" >&2
    exit 42
    ;;
  NO_OUTPUT)
    emit_jsonl
    exit 0
    ;;
  INVALID_JSON)
    cat >"${OUTPUT_FILE}" <<'JSON'
{"loop_signal":
JSON
    emit_jsonl
    exit 0
    ;;
esac

LOOP_SIGNAL="${FIRST}"
if [[ "${FIRST}" == "SHOULDNT_CONTINUE" ]]; then
  REVIEW_OUTCOME="DONE"
  COMMIT_STATUS="SKIPPED"
  COMMIT_SHA=""
  DECISION_REASON="review worker reported DONE"
  ITERATION_SUMMARY="all spec checks passed"
elif [[ "${FIRST}" == "UNKNOWN_CONTINUE" ]]; then
  LOOP_SIGNAL="CONTINUE"
  REVIEW_OUTCOME="UNKNOWN"
  COMMIT_STATUS="UNKNOWN"
  COMMIT_SHA=""
  DECISION_REASON="worker failure fallback"
  ITERATION_SUMMARY="failure was handled via CONTINUE fallback"
elif [[ "${FIRST}" == "INVALID_SIGNAL" ]]; then
  LOOP_SIGNAL="MAYBE"
  REVIEW_OUTCOME="UNKNOWN"
  COMMIT_STATUS="UNKNOWN"
  COMMIT_SHA=""
  DECISION_REASON="intentional invalid signal for testing"
  ITERATION_SUMMARY="invalid branch"
else
  REVIEW_OUTCOME="NOT_DONE"
  COMMIT_STATUS="COMMITTED"
  COMMIT_SHA="fake-commit-${COUNT}"
  DECISION_REASON="review worker reported gaps"
  ITERATION_SUMMARY="implementation and commit were dispatched"
fi

cat >"${OUTPUT_FILE}" <<JSON
{"loop_signal":"${LOOP_SIGNAL}","decision_reason":"${DECISION_REASON}","iteration_summary":"${ITERATION_SUMMARY}","review_outcome":"${REVIEW_OUTCOME}","worker_id":"fake-worker-1","commit_status":"${COMMIT_STATUS}","commit_sha":"${COMMIT_SHA}"}
JSON

emit_jsonl
