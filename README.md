# Minimal Subagent Supervisor Loop (Codex CLI)

This example implements a restartable supervisor loop for Codex CLI that uses one disposable worker per iteration:

1. Worker runs review prompt.
2. If review says done: supervisor emits `SHOULDNT_CONTINUE` and stops.
3. If review says not done: worker runs implementation prompt, then commit prompt; supervisor emits `CONTINUE`.
4. External bash harness restarts a fresh supervisor session while signal is `CONTINUE`.

## Files

- `prompts/supervisor.md`: supervisor orchestration prompt.
- `prompts/worker_review.md`: pre-canned review prompt.
- `prompts/worker_implement.md`: pre-canned implementation prompt.
- `prompts/worker_commit.md`: pre-canned commit prompt.
- `schemas/supervisor_output.schema.json`: strict final output contract for supervisor.
- `demo/task_spec.md`: toy build spec used by review and implementation.
- `scripts/setup_demo_workspace.sh`: creates a clean toy git repo workspace.
- `scripts/run_supervisor_loop.sh`: restart harness + supervisor execution loop.
- `scripts/fake_codex.sh`: deterministic Codex simulator for local e2e tests.
- `scripts/test_e2e.sh`: automated checks for loop/restart behavior.
- `scripts/test_live_e2e.sh`: optional real-model integration checks.
- `scripts/run_live_demo.sh`: optional live run using real `codex`.

## Run deterministic e2e tests (no model/network required)

```bash
scripts/test_e2e.sh
```

What it validates:

1. `CONTINUE -> CONTINUE -> SHOULDNT_CONTINUE` path is hit.
2. Supervisor process is restarted each loop (multiple invocations).
3. Fallback `CONTINUE` path with `review_outcome=UNKNOWN`.
4. Restart context branch (existing `last_supervisor_output` reused on next start).
5. Invalid restart state JSON is quarantined and bootstrap context is used.
6. Strict supervisor output contract validation (shape + enums) is enforced.
7. All harness error exits (`2/10/11/12/13/14`) and their trigger conditions.
8. Extensible history metadata injection works.
9. Prompt/task/schema asset preflight validates missing and empty files.
10. Max-loop guard exits non-zero when the signal never switches.

## Configurable Inputs (backward-compatible defaults)

`scripts/run_supervisor_loop.sh` supports path and metadata overrides while keeping prior defaults:

- `--prompts-dir`
- `--supervisor-prompt`
- `--worker-review-prompt`
- `--worker-implement-prompt`
- `--worker-commit-prompt`
- `--schema-path`
- `--task-spec-path`
- `--history-metadata-json`
- `--history-metadata-file`

Argument parsing is left-to-right, and later flags override earlier flags.

Examples:

```bash
# Use an alternate prompt bundle directory (expects supervisor.md + worker_*.md inside).
scripts/run_supervisor_loop.sh \
  --workspace /tmp/codex-subagent-demo-live \
  --prompts-dir /path/to/my-prompts
```

```bash
# Mix explicit paths for each artifact.
scripts/run_supervisor_loop.sh \
  --workspace /tmp/codex-subagent-demo-live \
  --supervisor-prompt /path/supervisor.md \
  --worker-review-prompt /path/review.md \
  --worker-implement-prompt /path/implement.md \
  --worker-commit-prompt /path/commit.md \
  --schema-path /path/supervisor_output.schema.json \
  --task-spec-path /path/task_spec.md
```

```bash
# Attach run metadata directly.
scripts/run_supervisor_loop.sh \
  --workspace /tmp/codex-subagent-demo-live \
  --history-metadata-json '{"run_id":"2026-02-16-a","ticket":"ENG-1234"}'
```

```bash
# Or load metadata from a file.
scripts/run_supervisor_loop.sh \
  --workspace /tmp/codex-subagent-demo-live \
  --history-metadata-file /path/history_metadata.json
```

If `--prompts-dir` and per-file prompt flags are both used, whichever appears later on the command line wins.

## History Metadata

Each line in `.orchestrator/state/supervisor_history.jsonl` includes:

- the supervisor output contract fields (`loop_signal`, `review_outcome`, etc.)
- `iteration`
- `history_metadata` with stable run context (`timestamp_utc`, `workspace`, `model`, paths for schema/task/prompts)
- optional `history_metadata_extra` when `--history-metadata-json` or `--history-metadata-file` is provided

Minimal example (single JSONL record):

```json
{
  "loop_signal": "CONTINUE",
  "review_outcome": "NOT_DONE",
  "iteration": 1,
  "history_metadata": {
    "timestamp_utc": "2026-02-16T12:34:56Z",
    "workspace": "/tmp/codex-subagent-demo-live",
    "model": "gpt-5.3-codex",
    "schema_path": "/repo/schemas/supervisor_output.schema.json",
    "task_spec_path": "/repo/demo/task_spec.md",
    "prompt_paths": {
      "supervisor": "/repo/prompts/supervisor.md",
      "worker_review": "/repo/prompts/worker_review.md",
      "worker_implement": "/repo/prompts/worker_implement.md",
      "worker_commit": "/repo/prompts/worker_commit.md"
    }
  },
  "history_metadata_extra": {
    "run_id": "2026-02-16-a"
  }
}
```

## Coverage Matrix

| Path/Branch | Expected behavior | Deterministic coverage (`test_e2e.sh`) | Live coverage (`test_live_e2e.sh`) |
|---|---|---|---|
| Unknown CLI arg | Exit `2`, prints `Unknown argument` | `run_error_branch_tests` | N/A |
| Missing `jq` | Exit `2`, prints `jq is required` | `run_error_branch_tests` | N/A |
| Missing workspace | Exit `2`, prints `Workspace does not exist` | `run_error_branch_tests` | N/A |
| Missing schema file | Exit `2`, prints `Schema not found` | `run_error_branch_tests` | N/A |
| Missing prompt file | Exit `2`, prints prompt-not-found error | `run_error_branch_tests` | N/A |
| Empty prompt file | Exit `2`, prints prompt-empty error | `run_error_branch_tests` | N/A |
| Missing task spec file | Exit `2`, prints `Task spec not found` | `run_error_branch_tests` | N/A |
| Invalid `--history-metadata-json` | Exit `2`, prints metadata object error | `run_error_branch_tests` | N/A |
| Supervisor command failure | Exit `10` | `run_runtime_failure_branch_tests` (`FAIL`) | N/A |
| Supervisor wrote no output file | Exit `11` | `run_runtime_failure_branch_tests` (`NO_OUTPUT`) | N/A |
| Supervisor output invalid JSON | Exit `12` | `run_runtime_failure_branch_tests` (`INVALID_JSON`) | N/A |
| Supervisor output invalid shape | Exit `12` | `run_runtime_failure_branch_tests` (`INVALID_SHAPE`) | N/A |
| Supervisor output invalid signal | Exit `13` | `run_runtime_failure_branch_tests` (`INVALID_SIGNAL`) | N/A |
| Happy loop progression | `CONTINUE -> ... -> SHOULDNT_CONTINUE`, exit `0` | `run_main_path_test` | `run_live_normal_path_test` |
| Fallback-style continue | `CONTINUE` with `review_outcome=UNKNOWN` accepted | `run_unknown_fallback_path_test` | N/A |
| Restart context reuse | previous `last_supervisor_output` injected into next prompt | `run_restart_context_branch_test` | Covered implicitly by repeated live runs |
| Invalid restart context recovery | Corrupt prior output is quarantined; bootstrap context used | `run_restart_state_recovery_test` | N/A |
| History metadata extension | Extra metadata fields are preserved in history entries | `run_history_metadata_extension_test` | N/A |
| Max-loop guard | Exit `14` after `MAX_LOOPS` without terminal signal | `run_max_loop_guard_test` | `run_live_max_loop_path_test` |
| Real collab lifecycle | Each live iteration completes `spawn_agent` then `close_agent` | N/A | `run_live_normal_path_test`, `run_live_max_loop_path_test` |
| Fake codex missing required arg | Exit `2` in simulator | `run_fake_codex_script_branch_tests` | N/A |
| Fake codex empty sequence fallback | Defaults to `SHOULDNT_CONTINUE` | `run_fake_codex_script_branch_tests` | N/A |

## Run against real Codex

```bash
scripts/run_live_demo.sh
```

Optional live integration checks:

```bash
scripts/test_live_e2e.sh
```

Or manually:

```bash
scripts/setup_demo_workspace.sh /tmp/codex-subagent-demo-live
scripts/run_supervisor_loop.sh \
  --workspace /tmp/codex-subagent-demo-live \
  --max-loops 6 \
  --model gpt-5.3-codex
```

Outputs are written under the workspace:

- `.orchestrator/logs/`: per-iteration JSONL + stderr logs.
- `.orchestrator/state/supervisor_history.jsonl`: one summary JSON per iteration.
- `.orchestrator/state/last_supervisor_output.json`: latest supervisor terminal signal JSON.

## Troubleshooting

| Symptom (stderr) | Meaning | Action |
|---|---|---|
| `jq is required` | `jq` is not available in `PATH`. | Install `jq` and re-run. |
| `Workspace does not exist: ...` | `--workspace` points to a missing path. | Create the workspace or fix the path. |
| `... prompt not found` / `... prompt is empty` | Required prompt asset is missing/empty. | Restore the prompt file and ensure non-empty content. |
| `Task spec not found: ...` | Task spec path is invalid. | Point `--task-spec-path` to a valid markdown spec file. |
| `history metadata must be a JSON object` | Metadata input is invalid JSON or not an object. | Pass valid JSON object text/file content. |
| `Supervisor output does not match expected contract` | Supervisor returned missing/invalid required fields. | Inspect `.orchestrator/logs/supervisor_iter_*.jsonl` and align prompt/output behavior. |
| `Invalid loop_signal '...'` | Supervisor emitted unsupported loop signal. | Ensure final output uses only `CONTINUE` or `SHOULDNT_CONTINUE`. |
| `Warning: invalid previous supervisor output JSON moved to ...` | Restart checkpoint was corrupt. | Optional: inspect quarantined file; loop continues using bootstrap context automatically. |
