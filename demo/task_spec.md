# Dummy Build Task Spec

Goal: finish a 2-phase toy build in a git repo.

Required final state:
1. `build_state.json` exists and equals `{ "current_phase": 2 }`.
2. `output/phase1.txt` exists with exact text `phase1 complete` plus trailing newline.
3. `output/phase2.txt` exists with exact text `phase2 complete` plus trailing newline.
4. `output/final.txt` exists with exact text `build complete` plus trailing newline.

Intentional phased policy (for loop testing):
1. A single implementation turn may advance at most one phase.
2. If `current_phase` is `0`, implementation should only create/update phase-1 artifacts and set phase to `1`.
3. If `current_phase` is `1`, implementation should only create/update phase-2/final artifacts and set phase to `2`.
4. If `current_phase` is already `2`, implementation should make no file changes.

Review outcome rules:
1. If all required final-state conditions pass, review outcome is `DONE`.
2. Otherwise review outcome is `NOT_DONE` with concrete gaps.
