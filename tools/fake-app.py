#!/usr/bin/env python3
"""A stand-in for every app a test menu runs: logs its argv, runs nothing.

tools/gallery.sh puts one small wrapper per command name from
appring/default.json first on PATH; each wrapper calls

    fake-app.py NAME ARGS...

which appends one JSON array, ["NAME", ARGS...], to $FAKE_APP_LOG. So a
commit never starts a real application, and the test sees exactly the
arguments the ring passed.
"""
import json
import os
import sys
from pathlib import Path

with Path(os.environ["FAKE_APP_LOG"]).open("a") as log:
    log.write(json.dumps(sys.argv[1:]) + "\n")
