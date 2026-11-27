#!/usr/bin/env python3
"""Minimal patcher used by the dfroot-custom workflow."""
import sys
import shutil

def main():
    if len(sys.argv) != 2:
        print("usage: patch_ko.py <ko>")
        sys.exit(1)
    src = sys.argv[1]
    dst = src + ".patched"
    shutil.copy(src, dst)
    print(f"copied {src} -> {dst}")

if __name__ == "__main__":
    main()
