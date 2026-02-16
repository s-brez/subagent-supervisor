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
5. All harness error exits (`2/10/11/12/13/14`) and their trigger conditions.
6. Max-loop guard exits non-zero when the signal never switches.

## Coverage Matrix

| Path/Branch | Expected behavior | Deterministic coverage (`test_e2e.sh`) | Live coverage (`test_live_e2e.sh`) |
|---|---|---|---|
| Unknown CLI arg | Exit `2`, prints `Unknown argument` | `run_error_branch_tests` | N/A |
| Missing `jq` | Exit `2`, prints `jq is required` | `run_error_branch_tests` | N/A |
| Missing workspace | Exit `2`, prints `Workspace does not exist` | `run_error_branch_tests` | N/A |
| Missing schema file | Exit `2`, prints `Schema not found` | `run_error_branch_tests` | N/A |
| Supervisor command failure | Exit `10` | `run_runtime_failure_branch_tests` (`FAIL`) | N/A |
| Supervisor wrote no output file | Exit `11` | `run_runtime_failure_branch_tests` (`NO_OUTPUT`) | N/A |
| Supervisor output invalid JSON | Exit `12` | `run_runtime_failure_branch_tests` (`INVALID_JSON`) | N/A |
| Supervisor output invalid signal | Exit `13` | `run_runtime_failure_branch_tests` (`INVALID_SIGNAL`) | N/A |
| Happy loop progression | `CONTINUE -> ... -> SHOULDNT_CONTINUE`, exit `0` | `run_main_path_test` | `run_live_normal_path_test` |
| Fallback-style continue | `CONTINUE` with `review_outcome=UNKNOWN` accepted | `run_unknown_fallback_path_test` | N/A |
| Restart context reuse | previous `last_supervisor_output` injected into next prompt | `run_restart_context_branch_test` | Covered implicitly by repeated live runs |
| Max-loop guard | Exit `14` after `MAX_LOOPS` without terminal signal | `run_max_loop_guard_test` | `run_live_max_loop_path_test` |
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
