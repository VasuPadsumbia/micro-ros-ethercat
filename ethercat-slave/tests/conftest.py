"""
conftest.py — pytest configuration for cocotb-based FPGA simulation tests.

Each test module corresponds to one RTL module.  cocotb runs the simulation
using iverilog (free, available via apt).

Environment:
  SIM=icarus          (default)
  COCOTB_RESOLVE_X=ZEROS

Dependencies (from requirements.txt):
  cocotb>=1.8
  pytest>=7.4
"""
import os
import pytest

# Tell cocotb which simulator to use (override with SIM env var)
os.environ.setdefault("SIM", "icarus")
os.environ.setdefault("COCOTB_RESOLVE_X", "ZEROS")

# RTL source root (relative to this file)
RTL_DIR = os.path.join(os.path.dirname(__file__), "..", "rtl")


def rtl(*files) -> list[str]:
    """Return absolute paths to RTL source files."""
    return [os.path.join(RTL_DIR, f) for f in files]
