#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compatibility entry point; use scripts/android/build.py for Android releases."""
from pathlib import Path
import runpy

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).resolve().parent / "android/build.py"),
                   run_name="__main__")
