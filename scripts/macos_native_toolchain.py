#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Compatibility entry point; native macOS tooling lives in scripts/macos/."""
from pathlib import Path
import runpy
import sys

if __name__ == "__main__":
    runpy.run_path(str(Path(__file__).resolve().parent / "macos/native_toolchain.py"),
                   run_name="__main__")
else:
    from macos.native_toolchain import prepare_native_environment
