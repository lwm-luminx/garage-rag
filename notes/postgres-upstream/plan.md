# Upstreaming Garage's sandboxed-Postgres patch to PostgreSQL

Plan and research, 2026-09-27. Nothing here has been sent to any PostgreSQL list.

## 1. What we carry today

The App Store build of Garage runs the bundled server under the App Sandbox
(`macapp/externals/GarageServer.entitlements`: `app-sandbox` + `inherit`, so
`postgres` takes on GarageApp's sandbox). The sandbox denies the whole System V
IPC family (`shmget`/`shmat`/`shmctl`, `semget`/`semop`/`semctl`), which upstream
PostgreSQL still needs on macOS in two places even with
`shared_memory_type = mmap`:

1. **The shared-memory interlock.** `PGSharedMemoryCreate` always creates a
   System V segment. With `mmap` it is only a `sizeof(PGShmemHeader)` shim, whose
   `shm_nattch` count is the only way the postmaster can tell whether backends of
   a crashed postmaster are still attached to the data directory
   (`PGSharedMemoryIsInUse`, called from `CreateLockFile` when `postmaster.pid`
   names a dead PID). The header comment of `sysv_shmem.c` says so verbatim:
   "We still require a SysV shmem block to exist, though, because mmap'd shmem
   provides no way to find out how many processes are attached, which we need
   for interlocking purposes."
2. **Semaphores.** `src/template/darwin` and `meson.build` select System V
   semaphores on every Darwin newer than 10.1. The two POSIX alternatives don't
   fit macOS: `sem_init` (unnamed) returns `ENOSYS` on Darwin, and `sem_open`
   (named) costs one file descriptor per backend per semaphore and is not
   allowed in the sandbox without an app-group name prefix anyway.

`ext/postgres/sysv_shmem.patch` (PG 18.6) and `ext/postgres19/sysv_shmem.patch`
(REL_19_BETA4, ported to `PGSemaphoreShmemRequest`/`ShmemRequestStruct`) are
applied by the Bazel `http_archive`/`git_repository` rules. They do five things:

| File | Change | Why the sandbox needs it |
|---|---|---|
| `src/backend/port/sysv_shmem.c` | Deletes `InternalIpcMemoryCreate`, `PGSharedMemoryAttach`, `IpcMemoryDetach/Delete` and the key-search loop. `PGSharedMemoryCreate` always mmaps (`shared_memory_type` is ignored), writes `"<inode> 0"` as line 7 of `postmaster.pid`, and `PGSharedMemoryIsInUse` returns `false`. | `shmget` fails with `EPERM` under the sandbox before the first byte of shared memory exists. |
| `src/backend/port/posix_sema.c` | Keeps the named (`sem_open`) implementation as is; replaces the unnamed one with a new `PGSemaphoreData` = process-shared `pthread_mutex_t` + `pthread_cond_t` + `int count` in the shared memory array. `Lock`/`Unlock`/`TryLock`/`Reset` are the textbook counting-semaphore over mutex+condvar. | `semget` is denied; `sem_init` is `ENOSYS` on Darwin, so upstream's unnamed code cannot be selected there. Process-shared pthread primitives work across `fork()` on macOS and need no kernel object name. |
| `src/include/storage/pg_sema.h` | `#ifdef __APPLE__`: undefines `USE_SYSV_SEMAPHORES`/`USE_NAMED_POSIX_SEMAPHORES`, defines `USE_UNNAMED_POSIX_SEMAPHORES`. | Forces the new implementation regardless of what configure chose. |
| `src/template/darwin` | Replaces the `case $host_os` block with `USE_UNNAMED_POSIX_SEMAPHORES=1`. | Same, at configure time (autoconf build only; `meson.build` is untouched, which is why the header hack exists). |
| `src/common/username.c` | `get_user_name()` returns `$PGUSER`, then `$USER`, then `getpwuid()`, and falls back to `"postgres"` instead of erroring. | Observed `getpwuid` failure (or hang) inside the sandbox when Directory Services is unreachable; the app passes `-U` explicitly anyway. |

The Bazel rule also seds `postgresql.conf.sample` to default
`shared_memory_type`/`dynamic_shared_memory_type` to `mmap`, and the app passes
both on the `initdb` and `postgres` command lines
(`PostgresService.swift`).

### What is wrong with the patch as an upstream submission

It is a fork, not a feature: it deletes the System V shared-memory code path
for every platform (Linux users setting `shared_memory_type = sysv` would
silently get mmap), removes the crash-interlock entirely (`PGSharedMemoryIsInUse`
returning `false` means a postmaster can start over orphaned backends of a
`kill -9`'d predecessor, which upstream regards as a data-corruption hazard),
hard-codes the platform in a header, only touches the autoconf side, and changes
`get_user_name()` semantics for every client program (`PGUSER` is a connection
parameter, not the OS user name; `pg_ctl`, `initdb` and `pg_basebackup` rely on
the current behavior). None of that can land. The ideas behind it can.

## 2. How PostgreSQL takes patches, and what has been said before

Sources were read on 2026-09-27; message-id links are permanent.

### Process

- **Venue.** Everything happens on pgsql-hackers first, then the thread is
  registered in the open CommitFest at https://commitfest.postgresql.org/.
  The app auto-detects new patch versions posted to the thread and runs CI on
  them (cfbot). Statuses: Needs review, Waiting on Author, Ready for
  Committer, then Committed / Returned with Feedback / Rejected.
- **Calendar.** The v19 feature freeze was 2026-04-08; PG 19 is in beta 4
  (2026-09-24). The commitfest app shows PG20-2 in progress until 2026-09-30
  (closed to new entries), **PG20-3 open for entries until 2026-10-31** and in
  progress through November, PG20-4 in January 2027, PG20-Final in March 2027.
  Register in PG20-3. Big features are expected by the January CF, not the
  final one.
- **Patch format.** `git format-patch -vN` against master, `.patch` files,
  one thread per topic, each mail describing what, why, target branch, tests,
  docs, platforms tested (https://wiki.postgresql.org/wiki/Submitting_a_Patch).
  "The fastest way to get your patch rejected is to make unrelated changes."
  Run `git diff --check`, `pgindent`, `pgperltidy`. WIP patches are labelled
  as such. Each submitter is expected to review one other patch of similar
  size in the same CF (https://wiki.postgresql.org/wiki/Reviewing_a_Patch).
  Commit messages end with `Discussion: https://postgr.es/m/<message-id>`;
  release notes are written by the release team from commit messages
  (https://wiki.postgresql.org/wiki/Committing_checklist).
- **Build systems.** autoconf (`configure.ac` plus the committed `configure`)
  and meson both stay
  (https://wiki.postgresql.org/wiki/Meson). A new port symbol goes into
  `configure.ac`, `src/include/pg_config.h.in`, `meson.build` and
  `src/backend/port/meson.build` together.
- **CI.** master moved from Cirrus to GitHub Actions
  (`.github/workflows/pg-ci.yml`): Linux autoconf and meson, **macOS 15 with
  meson** (MacPorts), Windows, CompilerWarnings. A fork enables it with the
  repo variable `PG_CI_ENABLED=1`. REL_18_STABLE still carries the Cirrus
  files. After commit, the buildfarm covers the odd platforms.
- **Tests and docs.** TAP tests under `src/test/perl` conventions
  (`PostgreSQL::Test::Cluster`), pg_regress where SQL suffices.
  `doc/src/sgml/runtime.sgml` "Shared Memory and Semaphores" still says
  "POSIX semaphores are used on Linux and FreeBSD systems while other
  platforms use System V semaphores" and has the macOS `kern.sysv.*`
  subsection; `installation-platform-notes.sgml` has the macOS notes.
- **Who decides.** Tom Lane and Thomas Munro authored every relevant commit
  and thread; expect them to be the reviewers.

### Prior discussion that matters

1. **The sandbox has been reported upstream already.** Wolfgang Walther,
   September 2025, "PostgreSQL fails to start inside Nix' darwin sandbox":
   `could not create shared memory segment: Operation not permitted`,
   `shmget(key=..., size=56, 03600)`, and a request for a **run-time** rather
   than compile-time answer, so one binary works inside and outside the
   sandbox
   (https://www.postgresql.org/message-id/a90b5411-705f-4286-bd81-a26c520a6cfb%40technowledgy.de).
   Thomas Munro's reply is the design brief for Patch A: "For the tiny
   'interlocking' memory segment ... I agree that it would be nice to get rid
   of it. Off the cuff ideas: Perhaps the postmaster could exclusively lock a
   file at startup but only briefly, and then backends could individually
   share-lock it ... Or perhaps the postmaster could bind to a dummy AF_UNIX
   socket under pgdata at startup, since no process can bind to that address
   again until all children that inherited the socket have exited", and "The
   next problem will be System V semaphores. I posted a patch that uses macOS
   futexes to implement semaphores"
   (https://www.postgresql.org/message-id/CA%2BhUKGJoOCA5PmhqU5P8gWe2Am%3DO-f0ubDjUed2kPuLRWe-UEg%40mail.gmail.com).
   Nobody followed up with code. Reply on this thread.
2. **Upstream's preferred semaphore replacement is a futex, and the patch
   exists.** Munro, August 2025, "Use futex-based semaphore emulation on
   macOS", v2 at
   https://www.postgresql.org/message-id/CA%2BhUKGKRQrJhVYBkmLJZsScJ434qiduWzzpB0-0_FW8z1kTjcw%40mail.gmail.com:
   a counting semaphore over `os_sync_wait_on_address` (public since macOS
   14.4, with `OS_SYNC_WAIT_ON_ADDRESS_SHARED` for cross-process use) in the
   mmap'd segment, chosen automatically unless `MACOSX_DEPLOYMENT_TARGET`
   is 14.3 or lower; build knobs `sema_type = "unnamed_posix+emulation"`
   (meson) and `PREFERRED_SEMAPHORES="UNNAMED_POSIX+EMULATION"` (configure);
   "doesn't seem to be any slower". Greg Burd reviewed it favourably; the
   thread went quiet on 2025-08-16 and it is not in master. It grew out of
   Gavin Panella's `semget` crash report
   (https://www.postgresql.org/message-id/CALL7chmzY3eXHA7zHnODUVGZLSvK3wYCSP0RmcDFHJY8f28Q3g%40mail.gmail.com),
   where Tom Lane said the semget problem "remains a live problem on macOS,
   NetBSD, and OpenBSD".
3. **Why macOS is on System V semaphores at all.** Tom Lane, 2016: macOS
   "seems not to have unnamed POSIX semaphores, only named ones (the
   functions exist, but they always fail with ENOSYS)", and named ones cost a
   descriptor per semaphore per backend
   (https://www.postgresql.org/message-id/8536.1475704230@sss.pgh.pa.us). In
   December 2024 Andres Freund asked again whether to move the SysV
   platforms to POSIX semaphores
   (https://www.postgresql.org/message-id/sq77vv7tyauj7c5qcf3m4qtfbgcj2wcy7ieia3z7ctezwl4vy6%40wgctyzx3hnte);
   the only outcome was Solaris moving to unnamed POSIX in PG 19. No commit
   changed the macOS default.
4. **Every attempt to drop the SysV shmem interlock failed on the same
   objection.** Tom Lane on the 2011 POSIX-shmem patch: "Postmaster children
   have to reacquire the lock after forking, because fcntl locks aren't
   inherited during fork(). And that means you can't tell whether there's a
   just-started backend that hasn't yet acquired the lock"
   (https://www.postgresql.org/message-id/11177.1302564306%40sss.pgh.pa.us),
   and "accidentally trying to start a duplicate postmaster on the same
   machine is an everyday occurrence"
   (https://www.postgresql.org/message-id/4477.1302752272@sss.pgh.pa.us).
   Noah Misch's "Weaker shmem interlock w/o postmaster.pid" (2013 to 2019)
   explains why `shm_nattch` matters: a backend that blocked SIGQUIT survives
   an immediate shutdown, and the next postmaster must still see it
   (https://www.postgresql.org/message-id/20130912022800.GB260242%40tornado.leadboat.com,
   https://www.postgresql.org/message-id/20181203004106.GA2860387%40rfd.leadboat.com).
   Craig Ringer proposed `flock(2)` in 2018 precisely because it is inherited
   across fork
   (https://www.postgresql.org/message-id/CAMsr%2BYE363auKC%2B%3DGFdHnRw25rxrTVypXuXMt-9gqyxzKeDk7g%40mail.gmail.com).
   James Hilliard's 2020 Mach-shmem port was returned as "95% copy-and-paste
   from sysv_shmem.c" and because "the fact that sysv shmem is globally
   accessible is exactly why we use it"
   (https://www.postgresql.org/message-id/20201122081930.12375-1-james.hilliard1@gmail.com).
   The shim itself dates from the `shared_memory_type` commit f1bebef60e
   (2019, Munro reviving Andres's patch).
   **So a replacement must:** be held from before the first fork with no
   window in which a live child is invisible; catch orphans when
   `postmaster.pid` is gone; keep line 7 of `postmaster.pid`; not delete the
   SysV path. `flock` on an inherited descriptor meets the first; locking the
   data directory itself meets the second (upstream's own `017_shm.pl`
   deletes `postmaster.pid` and expects the orphan to be found).
5. **Apple's rules.** App Sandbox Design Guide: "System V semaphores are not
   supported in sandboxed apps"; POSIX semaphores and shared memory work only
   with names prefixed by the app group id and a slash, names at most 31
   bytes
   (https://developer.apple.com/library/archive/documentation/Security/Conceptual/AppSandboxDesignGuide/AppSandboxInDepth/AppSandboxInDepth.html).
   Apple DTS on the forums: System V IPC "doesn't have a good story regarding
   the App Sandbox", use `shm_open`
   (https://developer.apple.com/forums/thread/719897). A forum report says a
   `PTHREAD_PROCESS_SHARED` condvar returns `EINVAL` when two processes wait
   on it, because Darwin's condvar records the mutex address, which differs
   between processes that mapped the memory at different addresses
   (https://developer.apple.com/forums/thread/692476). PostgreSQL's forked
   backends inherit the segment at the same address, which masks this, but
   it is a real mark against pthread condvars as the upstream answer and a
   point for the futex design.

## 3. Proposed upstream design (written before the research and prototype; section 6 amends it)

Split the work into three independent patches, smallest and least controversial
first. Each stands alone, each has its own thread and commitfest entry, and the
App Sandbox is the motivating example rather than the design.

### Patch A: `shared_memory_type = mmap` without a System V shim

**Framing.** "Allow PostgreSQL to run on systems where System V IPC is
unavailable" (macOS App Sandbox, some containers with `seccomp` profiles that
deny `shmget`, systems with `kern.sysv.shmmni` exhausted). Not "make Garage
work".

**Design.** Keep the interlock, change what implements it. The interlock needs
one thing: a way for a new postmaster to learn whether any process of a dead
postmaster still has the old shared memory mapped. Two candidate mechanisms,
both already discussed on hackers:

1. **File lock held by every attached process.** At `PGSharedMemoryCreate`
   the postmaster opens a lock file in the data directory (a dedicated
   `postmaster.shmem-lock` file, or `postmaster.pid` itself) and takes a
   shared `fcntl(F_SETLK, F_RDLCK)` or `flock(LOCK_SH)` lock; every forked
   backend inherits the descriptor (`flock` locks are per open file
   description, so they survive `fork()`; POSIX `fcntl` locks are per process
   and would need each backend to take its own). A starting postmaster tries
   an exclusive lock with `F_SETLK`: success means nobody is attached, failure
   means orphans exist. This is the "briefly exclusive, then shared" scheme Thomas Munro
   sketched on Walther's thread (section 2); `flock` semantics make it work
   with `fork()` and `exec()` alike, and it does not depend on any IPC
   namespace. Locking the directory rather than `postmaster.pid` matters:
   upstream's `017_shm.pl` deletes `postmaster.pid` and still expects a live
   backend to be found.
   `PGSharedMemoryIsInUse` becomes "can I get the exclusive lock", which also
   removes the whole `SHMSTATE_*` key-collision analysis.
2. **`shm_nattch` on a POSIX segment.** `shm_open` + `fstat` gives no attach
   count on any platform, so this is not available. Rejected.

Recommended: option 1, gated behind `shared_memory_type = mmap` so the
System V and Windows paths are untouched. Concretely:

- New `src/backend/port/sysv_shmem.c` branch: when `shared_memory_type ==
  SHMEM_TYPE_MMAP` and a new configure/meson symbol `USE_MMAP_INTERLOCK`
  (or simply always on `mmap`) is set, skip `InternalIpcMemoryCreate` and take
  the file lock instead. `UsedShmemSegID` is written to `postmaster.pid` line 7
  as `0 0` (or the inode and 0) so `pg_ctl` and onlookers see the same line
  count; nothing but the postmaster reads that line. Document the format
  change in `pidfile.h`.
- `PGSharedMemoryIsInUse(id1, id2)` gains a file-lock probe path when `id2 == 0`.
- `EXEC_BACKEND`: backends must reacquire the shared lock after `exec()`; pass
  the fd number through the backend parameter file like the segment ID today,
  or simply keep the System V path mandatory for `EXEC_BACKEND` (upstream
  already accepts reduced functionality there).
- Windows unaffected (`win32_shmem.c` has its own interlock).

**Justification to write in the email.** The shim exists only for
`shm_nattch`. A file lock gives the same answer with fewer moving parts,
removes the key-collision search (a long-standing source of subtle bugs and
"pre-existing shared memory block is still in use" reports), and lets
`shared_memory_type = mmap` mean what its name says. That last point is the
hook: the parameter has been documented since PG 12 as the whole-server
choice, but `mmap` still needs a System V object today.

**Risks reviewers will raise, with answers ready.**

- *`flock` is not POSIX and behaves differently on NFS.* Use `fcntl` on
  platforms without `flock`; on NFS the data directory is already unsupported
  territory for `postmaster.pid` atomicity. `PostgreSQL::Test` already runs on
  every buildfarm OS; the buildfarm will find the odd one.
- *A backend that closes all descriptors (or a `dlopen`'d library that does)
  drops the lock silently.* Backends never close inherited descriptors below
  the `fd.c` reserved range; document the descriptor as reserved, and keep the
  System V path as the default until the mmap path has run a release cycle.
- *Why not just make it a new `shared_memory_type = mmap_nolock`?* Because the
  interlock is a correctness property; the point is to keep it, not to offer a
  way to turn it off.

### Patch B: a semaphore implementation for platforms without `sem_init`

**Framing.** "macOS: stop depending on System V semaphores". Motivation beyond
the sandbox: `kern.sysv.semmns` is 87 by default on macOS, so every macOS
install with `max_connections` above about 80 needs `sysctl` edits or
`launchctl` plist changes, which the documentation has carried a whole section
on since 8.x. Removing that section is the reviewer-visible benefit.

**Design.** The pthread-based counting semaphore in the Garage patch is sound
(the classic Dijkstra construction) but should be presented as a fourth
implementation file rather than by hijacking `USE_UNNAMED_POSIX_SEMAPHORES`:

- `src/backend/port/pthread_sema.c`, symbol `USE_PTHREAD_SEMAPHORES`, selected
  by `configure.ac`/`src/template/darwin` and `meson.build` (`sema_kind =
  'pthread'` for `host_system == 'darwin'`), with a configure check that
  `PTHREAD_PROCESS_SHARED` mutexes and condvars exist (`pthread_mutexattr_setpshared`).
- `PGSemaphoreData` = `pthread_mutex_t` + `pthread_cond_t` + `int count`,
  padded to `PG_CACHE_LINE_SIZE` like `SemTPadded`; lives in the shared memory
  array, so it works with `fork()` and (unlike named semaphores) with
  `EXEC_BACKEND`.
- Signals. `pthread_cond_wait` is not interrupted by signals, and that is
  fine: `sysv_sema.c` loops on `EINTR` and says "We used to check interrupts
  here, but that required servicing interrupts directly from signal handlers",
  so semaphore waits are already uninterruptible by design. On master the only
  callers are `lwlock.c` (waiter wake-ups) and `PGSemaphoreReset` in
  `proc.c`; long waits go through latches. Say this in the patch so nobody
  has to rediscover it.
- Destroying on shutdown: `pthread_mutex_destroy`/`pthread_cond_destroy` in
  the `on_shmem_exit` callback, as the patch does; note that after a backend
  crash the postmaster reinitializes shared memory, so a mutex held by the
  dead process is simply discarded with the mapping (no robust-mutex
  requirement).
- Benchmark: `pgbench -S` and a spinlock-contention test on an M-series Mac
  comparing System V semaphores to the pthread version; reviewers will ask.

**Alternative** to have ready: named POSIX semaphores with `sem_open` under a
per-data-directory name. Rejected on the FD-per-backend cost, the
`EXEC_BACKEND` gap (documented in `posix_sema.c`), and the sandbox name-prefix
rule. `os_unfair_lock`/`ulock_wait` (Darwin's futex) are private or process-local.

### Patch C: `get_user_name()` — do not upstream as written

The `PGUSER`/`USER` fallback changes client semantics and would be rejected.
Instead:

- Reproduce the `getpwuid` failure in a sandboxed test binary and record what
  errno it returns. If it is a genuine sandbox denial (Open Directory
  unreachable), the right upstream change is nothing: the app already passes
  `-U`. Garage should keep this hunk local, or drop it if the failure no longer
  reproduces on macOS 26.
- If a fallback is still wanted, propose only `getpwuid_r` failure →
  `getlogin_r` as a second lookup, with the error message unchanged. That is a
  one-hunk patch that can go in on its own if a reviewer agrees it is a real
  scenario, and should not be tied to A or B.

### Ordering and dependency

B is self-contained and has the clearest user-visible win (no more
`kern.sysv.*` tuning on macOS); send it first. A is the larger design
discussion; start the thread with a design email before code. C stays local.
Together A and B make an unpatched PostgreSQL run in the App Sandbox with
`shared_memory_type = mmap`; that becomes one sentence in each commit message,
not the headline.

## 4. Tests and documentation each patch needs

| | Patch A (interlock) | Patch B (pthread semaphores) |
|---|---|---|
| Regression | Whole `make check` / `meson test` on the buildfarm animals; no new SQL test makes sense. | Same; the LWLock and spinlock tests already exercise semaphores. |
| TAP | New `src/test/recovery/t/` or `src/test/modules/test_misc/t/` test: start a cluster, `kill -9` the postmaster leaving a backend alive (`pg_sleep` in a session), assert the second start fails with "pre-existing shared memory block ... is still in use"; then kill the backend and assert start succeeds. This test does not exist upstream today for the System V path and is the argument that the new path is at least as safe. | A TAP test that starts a cluster with `max_connections = 1000` on macOS without `kern.sysv` changes (skip unless `$^O eq 'darwin'`). |
| CI | `.cirrus.tasks.yml` has a macOS task (Sonoma, homebrew or macports deps); make sure both configure and meson pick the new implementation and that the `mmap` interlock is exercised by setting `shared_memory_type = mmap` in the CI `PG_TEST_INITDB_EXTRA_OPTS`. | Same task; also Linux with `--with-pthread-semaphores` forced, to prove portability. |
| Docs | `doc/src/sgml/runtime.sgml` "Shared Memory and Semaphores": say that with `mmap` no System V shared memory is used; update the platform table (macOS row) and the `shared_memory_type` entry in `config.sgml`. `pidfile.h` comment for line 7. | Same section: remove the macOS `kern.sysv.semmns` paragraph, or mark it as applying only to `--with-sysv-semaphores` builds. `installation.sgml` for the configure option. |
| Release notes | A line each; the committer writes them, but a suggested sentence in the email helps. | Same. |
| Style | `pgindent` run, `src/tools/pgindent/typedefs.list` entry for any new struct (`PGSemaphoreData` is already there). No C99 declarations mid-block outside the accepted style, no `//` comments. | Same. |

## 5. Work Garage should do before the first email

1. **Reproduce cleanly on unpatched sources.** Build stock 18.6 with meson on
   the M4, run it under the sandbox with `shared_memory_type = mmap`, and
   capture the exact `shmget`/`semget` errors. The email needs "here is what
   fails" before "here is what I changed".
2. **Verify the `getpwuid` claim.** Same sandbox test binary. If it works on
   current macOS, patch C disappears.
3. **Rewrite the semaphore code as `pthread_sema.c`** against master (not 18)
   with both build systems, plus a `pgbench` comparison. That is the patch
   that gets attached to the first email.
4. **Prototype the file-lock interlock** and its TAP test, on master.
5. **Get a community account** (postgresql.org login is needed for the
   commitfest app), subscribe to pgsql-hackers, and read the current
   commitfest for anything touching `sysv_shmem.c`/`pg_sema.h` to rebase
   against and to cite.
6. **Pick the commitfest.** Patches sent now land in the next open CF (see
   section 2 for the calendar); a new contributor is expected to review at
   least one other patch of similar size in the same CF.
7. Keep the Bazel patch as is until the upstream versions exist; then carry
   the upstream patches (as `git format-patch` output against the release
   tarball) instead of the fork, so the diff Garage ships is exactly what was
   proposed.

## 6. What was built and tested today (Linux)

A prototype now exists and is what PR #164 ships in `ext/postgres/appstore.patch`
(https://github.com/rickmark/garage-rag/pull/164), 11 files, +628/-4 against
18.6. It follows Rick's direction of a build flag plus a file lock:

- `configure --enable-appstore` / `meson -Dappstore=true` defines `APPSTORE`
  and selects `src/backend/port/pthread_sema.c`. Both build systems are wired;
  `configure` was edited by hand alongside `configure.ac`, since autoconf 2.69
  was not available.
- `sysv_shmem.c` under `APPSTORE`: always mmap; a shared `flock()` on **the
  data directory** (a descriptor from `open(DataDir, O_RDONLY)`), taken after
  `CreateDataDirLockFile` and before the first fork. The probe is an exclusive
  `flock(LOCK_EX | LOCK_NB)`: from `PGSharedMemoryIsInUse` when
  `postmaster.pid` is stale, and inside `InterlockAcquire` itself, which
  catches the no-`postmaster.pid` case and reports the same "pre-existing
  shared memory block is still in use" error. `PGSharedMemoryDetach` closes
  the descriptor, so the syslogger does not hold the directory.
  `shared_memory_type = sysv` is refused with a clear error. `EXEC_BACKEND`
  is a compile error.
- First version locked `postmaster.pid`. Upstream's `017_shm.pl` unlinks that
  file and expects a live backend to still be detected; it failed, and moving
  the lock to the directory fixed it. Worth telling upstream: the existing
  test found the hole.
- `pthread_sema.c`: mutex + condvar + count, cache-line padded, in the main
  segment. Waits are uninterruptible like the other implementations.
- New TAP test `src/test/modules/test_misc/t/009_orphan_interlock.pl`
  (SIGSTOP a backend, kill -9 the postmaster, start must fail, kill the
  orphan, start must succeed with crash recovery). It passes on the
  APPSTORE build and is written to pass on a SysV build too.

Results, Linux x86_64, pristine 18.6 plus the patch:

| Check | Result |
|---|---|
| `patch -p1 --dry-run` of `appstore.patch` and `username.patch` on the tarball tree | clean |
| configure "which semaphore API to use" | pthread |
| `make check` (core regression) | 231 of 231 |
| `src/test/recovery` `013_crash_restart.pl`, `017_shm.pl` | pass |
| `test_misc` `009_orphan_interlock.pl` | pass |
| Same `017_shm.pl` on an unpatched SysV build (control) | pass |

Not done: any macOS build. The pthread semaphores and the directory `flock()`
inside the sandbox need an M4 run (`aspect build //:macapp --config=appstore`,
then the app's own smoke test) before this replaces what ships. The old
`get_user_name()` hunk is carried as `ext/postgres/username.patch` so the
sandbox behavior does not change while that claim is re-verified.

### Port to master and the v1 series (2026-09-27, later)

The 18.6 patch was ported onto PostgreSQL master (3c5d9d9, "Don't emit
garbage \[un]restrict (null) commands in pg_dump") and split into the
three commits the email describes, authored as Rick, exported with
`git format-patch -v1` to `patches/` beside this file (see
`patches/README.md`). Differences from the 18.6 version:

- `pthread_sema.c` uses master's `PGSemaphoreShmemRequest` /
  `PGSemaphoreInit` API with `ShmemRequestStruct`, instead of 18's
  `PGSemaphoreShmemSize` / `PGReserveSemaphores` and `ShmemAllocUnlocked`.
- `sysv_shmem.c` uses `hdr->content_offset` where 18 used `freeoffset`.
- The TAP test is `test_misc/t/016_orphan_interlock.pl` (015 exists on master).
- Docs: `installation.sgml` gets `--enable-appstore` and `-Dappstore` entries;
  `runtime.sgml` gets one paragraph in the kernel-resources section.
- `PGSemaphorePadded` added to `src/tools/pgindent/typedefs.list`; pgindent
  then reports no change for `pthread_sema.c` and `sysv_shmem.c`.
  `pgperltidy` was not run (no perltidy here); run it on the M4 before v1.

Results on master, Linux x86_64:

| Check | autoconf `--enable-appstore` | meson `-Dappstore=true` |
|---|---|---|
| semaphore API selected | pthread | pthread |
| core regression | 239 of 239 | pass (whole meson regress suite) |
| `test_misc` (incl. `016_orphan_interlock.pl`) | pass | pass (64 OK, 0 fail, 12 skipped for injection points) |
| `recovery` `013_crash_restart.pl`, `017_shm.pl` | pass | pass |
| `git diff --check` over the series | clean | |

macOS, 2026-09-27 21:30 (M3, Apple Silicon, PR #164 at 69b40df, the 18.6
form of the same patch):

- `aspect build //:macapp --config=appstore` passed; the app is sandboxed.
  The built server reports `--enable-appstore` in `pg_config --configure`,
  defines `APPSTORE`, imports no `semget`, and uses `flock`, `mmap` and
  process-shared pthread mutexes and condvars.
- Fresh data folder inside the sandbox: initdb and start with no sandbox
  denials; `postmaster.pid` line 7 reads `<inode> 0`; both shared-memory
  settings are mmap; add-source, ingest and search work through the bundled
  CLI; quit and relaunch brings the same cluster back with its data.
- Orphan interlock on the real binaries: backend stopped, postmaster killed
  with -9; `pg_ctl start` and `postgres --single` both refuse with
  "pre-existing shared memory block ... is still in use"; after killing the
  backend, start succeeds and a parallel query runs with 2 workers.
- Full log: `~/Developer/garage-rag-pr164/PR164-validation.md` on the M3.
- Noted for v2 of the series: `shmget`/`shmat`/`shmctl` are still imported,
  from `dsm_impl_sysv` only. Adding `#undef USE_DSM_SYSV` under `APPSTORE`
  (dynamic_shared_memory_type = sysv cannot work in the sandbox anyway)
  would remove the last System V references from the binary.

Still open before sending: `pgperltidy` on the TAP test, and the sandbox
test of Munro's futex patch.

### What changes in the design section after the research

- The interlock (Patch A) is on the right track and has Munro's own
  suggestion behind it. Present it on Walther's thread as "the flock variant
  of your first idea, with the lock on the directory so a deleted
  postmaster.pid does not hide orphans", with the TAP test and the `017_shm`
  result. Offer the runtime form Walther asked for: try `shmget`, and on
  `EPERM` fall back to the file lock, so one binary serves both sides of the
  sandbox; the build option would then only force the fallback.
- For semaphores (Patch B) the community direction is Munro's futex
  emulation, not pthread condvars, and the condvar address issue is a
  concrete reason. Best move: test his v2 patch inside the sandbox on the M4,
  review it on its thread, and offer the App Store use case as motivation to
  get it committed. Keep `pthread_sema.c` as Garage's fallback for macOS
  builds below 14.4 or if his patch stalls; it can be offered as an
  alternative in the same thread, but do not open a competing one.
- The `APPSTORE` name is fine for Garage's build. Upstream it becomes
  `--with-sysv-ipc=no` or a runtime fallback; say so in the email so the
  placeholder is not the topic.

## 7. The first pgsql-hackers email

The final text is in `email.md` beside this file (2026-09-29): a reply on
Wolfgang Walther's thread, plain text, with `patches/v1-000{1,2,3}-*.patch`
attached (rebased on master 6a93535 that day; autoconf and meson runs of
regress, test_misc/016 and recovery 013/017 all pass with the option on).
The testing paragraph claims only what was run: Linux on master, and the
18.6 form on Apple silicon inside the App Sandbox through Garage's build.
Munro's futex patch has not been tested in the sandbox; the email says so.
Rick sends it himself, then registers the thread in commitfest PG20-3
before 2026-10-31. v2 items: pgperltidy, `#undef USE_DSM_SYSV` under
APPSTORE, the futex sandbox result.
