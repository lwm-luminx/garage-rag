"""Fails when THIRD_PARTY_NOTICES.txt no longer covers Cargo.lock plus the bundled native components."""

import sys
from pathlib import Path

import third_party_notices

notices, lockfile = (Path(arg) for arg in sys.argv[1:3])
problems = third_party_notices.check(notices, lockfile)
for problem in problems:
    print(problem, file=sys.stderr)
if problems:
    print(
        "run `python3 tools/third_party_notices.py` and commit the result",
        file=sys.stderr,
    )
sys.exit(1 if problems else 0)
