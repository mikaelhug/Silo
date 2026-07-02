#!/usr/bin/env python3
"""Verify a compiled steamwebhelper wrapper carries the CORRECT CEF flags (UTF-16LE in the PE).

The wrapper is load-bearing: it must inject --in-process-gpu and must NOT inject --single-process
(which breaks Chromium's network service -> Steam login "Transport Error"). One shared check —
called by Scripts/build-wine.sh AND .github/workflows/build-wine.yml — so the guard can't drift
between the local and CI builds.

Usage: check-webhelper-wrapper.py <wrapper.exe>
"""
import sys

data = open(sys.argv[1], "rb").read()
ok = "--in-process-gpu".encode("utf-16-le") in data
bad = "--single-process".encode("utf-16-le") in data
if not ok or bad:
    sys.exit("ERROR: steamwebhelper wrapper has wrong CEF flags "
             f"(in-process-gpu={ok}, single-process={bad}) — check Scripts/steamwebhelper-wrapper.c")
print("wrapper CEF flags OK (--in-process-gpu)")
