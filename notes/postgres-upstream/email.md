# pgsql-hackers email (final text)

Reply on Wolfgang Walther's thread "PostgreSQL fails to start inside Nix' darwin sandbox"
(Message-ID `a90b5411-705f-4286-bd81-a26c520a6cfb@technowledgy.de`, archive:
https://postgr.es/m/a90b5411-705f-4286-bd81-a26c520a6cfb%40technowledgy.de).
Plain text, no HTML. Attach the three files in `patches/` (they are `git format-patch`
output against master 6a93535 of 2026-09-29; each applies with `git am`).

Header:

    To: pgsql-hackers@lists.postgresql.org
    Cc: Wolfgang Walther, Thomas Munro (the thread's participants; "Reply all" fills them in)
    Subject: Re: PostgreSQL fails to start inside Nix' darwin sandbox
    In-Reply-To: <a90b5411-705f-4286-bd81-a26c520a6cfb@technowledgy.de>

Body:

---

Hi,

On the sandbox question in this thread: I ship PostgreSQL inside a
sandboxed macOS application (a Mac App Store build), and the App Sandbox
denies the whole System V IPC family to the sandboxed process: shmget(),
shmat(), semget() and semop() all fail with EPERM. Two things in the
backend still need SysV IPC on macOS even with shared_memory_type = mmap:

1. sysv_shmem.c creates a sizeof(PGShmemHeader) SysV segment as a shim,
   because shm_nattch is the only way PGSharedMemoryIsInUse() can tell
   whether children of a crashed postmaster are still attached to the
   old shared memory.

2. src/template/darwin and meson.build select SysV semaphores on macOS,
   since sem_init() is unimplemented there (ENOSYS) and named POSIX
   semaphores cost a file descriptor per backend per semaphore.

I have been carrying a fork of sysv_shmem.c and posix_sema.c to work
around this and would like to replace it with something acceptable
upstream. Attached is a first attempt, in three patches against master.
Everything is behind a new build option, --enable-appstore
(-Dappstore=true), which is off by default, so a stock build is
unchanged; the option name is a placeholder.

0001 adds src/backend/port/pthread_sema.c, a counting semaphore made of
a PTHREAD_PROCESS_SHARED mutex, a condition variable and a counter,
living in the main shared memory segment like the unnamed-POSIX variant
does. It needs no kernel object name and no descriptors, and works with
fork()ed backends. Semaphore waits are not interruptible, which matches
the existing implementations. Thomas, I have read your futex-based
emulation patch; if that is the preferred direction I am happy to drop
0001 and help get yours in instead, and I will test it inside the
sandbox. I include mine because it also covers deployment targets below
macOS 14.4, where os_sync_wait_on_address() does not exist.

0002 is the flock() variant of Thomas's first idea, for
shared_memory_type = mmap: the postmaster asks for an exclusive flock()
on a descriptor of the data directory itself, downgrades it to shared,
and keeps the descriptor open; every child inherits it across fork(), so
there is no window in which a live child holds no lock. A later
postmaster probes with an exclusive lock, both from CreateLockFile()
when postmaster.pid is stale and in PGSharedMemoryCreate() when
postmaster.pid is gone, and fails exactly when an orphaned child still
exists. Locking the directory rather than postmaster.pid is what makes
the second case work; the existing recovery/017_shm.pl test, which
unlinks postmaster.pid, caught a first version that locked the file.
Children that detach from shared memory (PGSharedMemoryDetach) close the
descriptor, so the syslogger does not hold the data directory. Line 7 of
postmaster.pid keeps its two numbers. With this, an mmap server creates
no SysV object at all.

0003 adds a TAP test that freezes a backend with SIGSTOP, kill -9s the
postmaster, and checks that a new postmaster refuses to start until the
orphan is gone and then recovers. As far as I can see this behaviour was
not covered by any test before, for either interlock, so the test runs
in every build: it exercises shm_nattch in a stock build and the file
lock in an appstore build.

Questions I would like opinions on before polishing further:

- Is flock() acceptable as the primitive? fcntl() locks are per process
  and would need every backend to lock on its own; flock() locks are
  per open file description and survive fork(). Platforms without
  flock() would keep the SysV shim. I have not decided what to do on
  network filesystems, where flock() may be advisory only or missing.

- Wolfgang asked for a run-time answer. The build option in this
  version forces the file lock; a follow-up could try shmget() first
  and fall back to the lock on EPERM, so one binary works inside and
  outside the sandbox. Is that preferable to a GUC, or to tying the
  lock to shared_memory_type = mmap outright?

- Should the pthread semaphores be selectable on their own, apart from
  the interlock change?

Testing: on Linux (x86-64, glibc) with both build systems on today's
master, make check, the new test_misc/016_orphan_interlock.pl and
recovery/013_crash_restart.pl and 017_shm.pl all pass with the option
on; a stock build is untouched. The same change in its 18.6 form runs
in my application on Apple silicon, inside the App Sandbox, where a
stock server cannot start at all, and the orphan interlock behaves as
the test describes there too. I have not yet run the master series on
macOS outside the app build.

Regards,
Rick Mark

---

## After sending

1. Wait for the message to appear in the archive, then register the thread in
   CommitFest PG20-3 (https://commitfest.postgresql.org/, open until 2026-10-31):
   topic "System Administration", your archive link as the thread. The commitfest
   needs a community account tied to the address you send from, and pgsql-hackers
   only accepts mail from subscribed addresses.
2. The cfbot will apply and test the series on every platform. Reviewers' asks so
   far expected for v2: run `pgperltidy` on the TAP test (needs `perltidy`, easiest on
   a Mac: `brew install perltidy`, then `src/tools/pgindent/pgperltidy` in the tree);
   `#undef USE_DSM_SYSV` under APPSTORE so `dynamic_shared_memory_type = sysv` is not
   offered; and the sandbox result for Thomas Munro's futex semaphore patch.
