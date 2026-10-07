# Postgres 19 / Python 3.15 final-release watch

> Superseded 2026-09-28: tracking moved to the "Upstream Dependency Watcher" routine; this file is kept as the baseline.

Baseline recorded 2026-09-27 (thread "Watch for Postgres 19 and Python 3.15 final").
Checked via GitHub tags (python.org and postgresql.org are blocked by the cloud proxy):
`git ls-remote --tags https://github.com/postgres/postgres.git 'REL_19*'` and
`git ls-remote --tags https://github.com/python/cpython.git 'v3.15*'`.

| Upstream   | Latest tag today | Final tag to watch for |
|------------|------------------|------------------------|
| PostgreSQL | REL_19_BETA4 (b73d13c3) | REL_19_0 (REL_19_RC* is noted, not reported) |
| CPython    | v3.15.0rc2 (484b5ff9)   | v3.15.0 |

Garage pins today:
- `ext/postgres19/postgres19.MODULE.bazel`: REL_19_BETA4, still with the old `sysv_shmem.patch`
  (PR #164 replaces 18's patch with `appstore.patch`; 19 not yet ported). Opt-in via `--config=pg19`; 18 is default.
- `ext/python/python.MODULE.bazel`: 3.14.7 on v1.5-beta, 3.13.15 on main. `pyproject.toml`: `>=3.13,<3.15`.
- 3.15 eval (/mnt/project-files/python315/findings.md): suite passes on rc2; blocked on pydantic 2.14 final,
  grpcio 1.84, SQLAlchemy 2.1 cp315 wheels.

Last checked 2026-09-28: unchanged (REL_19_BETA4, v3.15.0rc2).

State: reported = none
