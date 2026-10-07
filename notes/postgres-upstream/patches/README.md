# v1 series for pgsql-hackers

Three patches against PostgreSQL master at 6a93535 (2026-09-29), made with
`git format-patch -v1`, author Rick Mark-Penwell:

| File | What |
|---|---|
| `v1-0001-Add-a-pthread-based-PGSemaphore-implementation-an.patch` | `src/backend/port/pthread_sema.c`, the `--enable-appstore` / `-Dappstore` option in configure.ac, configure, meson.build, meson_options.txt, `pg_config.h.in`, port/meson.build, installation.sgml, typedefs.list |
| `v1-0002-Use-a-file-lock-as-the-data-directory-interlock-i.patch` | `sysv_shmem.c` under `APPSTORE`: always mmap, directory `flock()` interlock; pidfile.h comment; runtime.sgml paragraph |
| `v1-0003-Add-a-TAP-test-for-the-data-directory-interlock.patch` | `src/test/modules/test_misc/t/016_orphan_interlock.pl` |

Each commit message ends with the `Discussion:` trailer for Wolfgang Walther's
"PostgreSQL fails to start inside Nix' darwin sandbox" thread, which the
email in `../plan.md` section 7 replies to.

To reproduce: clone postgres, `git checkout 6a93535`, `git am v1-*.patch`.
The commits are not signed; the format-patch files carry no signature
anyway, and the mailing list takes the files, not a branch.
