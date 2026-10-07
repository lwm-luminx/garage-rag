---
name: merge-main-into-next
description: Bring main's commits into next (or any release line forward) with a merge PR, resolving Garage's recurring conflicts. Use when asked to sync, catch up or flow main into next.
---

# Merge main into next

`next` is ruleset-protected (PR required, no force-push), so the merge goes through a PR merged with
"Create a merge commit" (a PR containing merge commits cannot be rebase-merged).

1. `git fetch origin main next && git checkout -B claude/<thread-branch> origin/next && git merge origin/main`.
2. Resolve conflicts. The usual ones:
   - `garage_python/src/garage_rag/proto/garage_pb2.py`: regenerate with the venv's `python -m grpc_tools.protoc`
     (CLAUDE.md, "Conventions"); keep the committed, post-processed `garage_pb2_grpc.py`.
   - Migrations: two `data/sql/0NN_*.sql` with the same number from each side. Both apply (migrate.py tracks full
     stems), but renumber `next`'s so the order is clear, and update references (docs/schema.md, db/models.py).
   - `data/models/models.json` sections and the Swift `ModelPresetGroups` that read them.
   - `MODULE.bazel.lock`: take one side and let Bazel regenerate it on a Mac; never hand-edit it.
3. Run the venv's `ruff check .`, `ruff format --check .` and `pytest` in `garage_python/`, and
   `tools/swiftcheck/check.sh` if Swift merged. `next`-only features can reference paths `main` moved.
4. Push, open the PR against `next` titled "Merge main into next", mark it ready once local checks pass, and ask
   Rick to merge with "Create a merge commit".
