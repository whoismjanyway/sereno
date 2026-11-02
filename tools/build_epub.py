#!/usr/bin/env python3
"""Zips an unpacked EPUB folder (such as a Standard Ebooks `src/` folder).

Usage: python3 tools/build_epub.py path/to/src out.epub
"""
import os
import sys
import zipfile


def build(src, out):
    with zipfile.ZipFile(out, "w") as z:
        z.write(os.path.join(src, "mimetype"), "mimetype", compress_type=zipfile.ZIP_STORED)
        for root, _dirs, files in os.walk(src):
            for name in sorted(files):
                path = os.path.join(root, name)
                arc = os.path.relpath(path, src)
                if arc != "mimetype":
                    z.write(path, arc, compress_type=zipfile.ZIP_DEFLATED)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    build(sys.argv[1], sys.argv[2])
