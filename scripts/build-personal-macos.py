#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compatibility entry point; native macOS tooling lives in scripts/macos/."""
from pathlib import Path
import runpy
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent / "macos"))

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).resolve().parent / "macos/build.py"),
                   run_name="__main__")
