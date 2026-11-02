#!/bin/sh
# Renders Sereno's home screen (and sample reader pages) with KOReader's
# real widget code. Prepares a small KOReader runtime folder on first use.
#
# Usage: tools/korender/run.sh <out_dir> [books_dir]
#
# Environment (all optional):
#   KOREADER_DIR       KOReader checkout        (default: ../koreader, cloned if missing)
#   KOREADER_BASE_DIR  koreader-base checkout   (default: ../koreader-base, cloned if missing)
#   KOREADER_FONTS_DIR koreader-fonts checkout  (default: ../koreader-fonts, cloned if missing)
#   LUAJIT             luajit binary            (default: luajit)
#   LUAJIT_INCLUDE     LuaJIT headers, to build the lfs module (default: /usr/include/luajit-2.1)
#   KORENDER_READER=1  also render reader pages (KOReader defaults vs Sereno's layout)
#   KORENDER_DEVICE    only one device: kindle-basic, paperwhite or scribe
#
# Needs: git, gcc, unzip, ImageMagick (convert), rsvg-convert, and the system
# FreeType library (libfreetype.so.6).
set -eu

OUT=$(realpath -m "$1")
BOOKS=${2:+$(realpath -m "$2")}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PARENT=$(dirname "$REPO")
KO=${KOREADER_DIR:-$PARENT/koreader}
BASE=${KOREADER_BASE_DIR:-$PARENT/koreader-base}
FONTS=${KOREADER_FONTS_DIR:-$PARENT/koreader-fonts}
LUAJIT=${LUAJIT:-luajit}
LUAJIT_INCLUDE=${LUAJIT_INCLUDE:-/usr/include/luajit-2.1}
RUNTIME=$PARENT/.sereno-korender

[ -d "$KO" ] || git clone --depth 1 https://github.com/koreader/koreader.git "$KO"
[ -d "$BASE" ] || git clone --depth 1 https://github.com/koreader/koreader-base.git "$BASE"
[ -d "$FONTS" ] || git clone --depth 1 https://github.com/koreader/koreader-fonts.git "$FONTS"

mkdir -p "$RUNTIME/libs" "$RUNTIME/common"
for f in frontend plugins resources defaults.lua datastorage.lua setupkoenv.lua; do
    ln -sfn "$KO/$f" "$RUNTIME/$f"
done
ln -sfn "$BASE/ffi" "$RUNTIME/ffi"
ln -sfn "$FONTS" "$RUNTIME/fonts"

FREETYPE=$(ldconfig -p 2>/dev/null | awk '/libfreetype.so.6 / {print $NF; exit}')
[ -n "$FREETYPE" ] || FREETYPE=/usr/lib/x86_64-linux-gnu/libfreetype.so.6
ln -sf "$FREETYPE" "$RUNTIME/libs/libfreetype.so.6"

# KOReader's lfs module is luafilesystem, built as a plain Lua C module
if [ ! -f "$RUNTIME/libs/libkoreader-lfs.so" ]; then
    LFS_SRC="$RUNTIME/luafilesystem"
    [ -d "$LFS_SRC" ] || git clone --depth 1 -b v1_9_0 https://github.com/lunarmodules/luafilesystem "$LFS_SRC"
    gcc -O2 -shared -fPIC -I"$LUAJIT_INCLUDE" -o "$RUNTIME/libs/libkoreader-lfs.so" "$LFS_SRC/src/lfs.c"
fi

cd "$RUNTIME"
"$LUAJIT" "$REPO/tools/korender/render.lua" "$REPO" "$OUT" ${BOOKS:+"$BOOKS"} 2>&1 \
    | grep -v -e '^lib_' -e 'monolibtic' -e '^ffi\.' -e ' INFO '
for f in "$OUT"/*.pgm; do
    [ -f "$f" ] && convert "$f" "${f%.pgm}.png" && rm "$f"
done
echo "PNG files in $OUT"
