#!/usr/bin/env bash
# Play a cartridge dump, with its save, in mGBA in a container. Runs on the
# HOST and drives podman itself.
#
#   tools/podman/play-dump.sh ZELDA.gbc              ROM alone
#   tools/podman/play-dump.sh ZELDA.gbc ZELDA.sav    ROM with its save RAM
#
# With no .sav given, one sitting beside the ROM under the same stem is used
# if it exists, because that is what the dumper writes and what mGBA expects.
#
# This is the end of the verification chain and the only part of it a checksum
# cannot do. A ROM's own header and global checksums prove the ROM read back
# intact; nothing equivalent exists for save RAM, which is why the save has to
# be loaded by the actual game and looked at. If your files, your hearts and
# your inventory are there, the SRAM read is good.
#
# WHAT THE FILES ARE COPIED FOR: mGBA writes to the .sav as you play. The
# originals are never mounted writable and never handed to the emulator; a
# temporary copy is, so a test can neither corrupt the dump nor write to the
# SD card the dump may still be sitting on.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"

PODMAN=${PODMAN:-podman}
IMAGE=${IMAGE:-localhost/pocket-emu:1}
WORK=${WORK:-$REPO/build/emu}
MGBA_SCALE=${MGBA_SCALE:-5}

usage() { sed -n '2,17p' "$0" | sed 's/^# \?//'; exit 1; }
[ $# -ge 1 ] || usage

ROM=$(readlink -f "$1")
[ -f "$ROM" ] || { echo "no such ROM: $1" >&2; exit 1; }
if [ $# -ge 2 ]; then
    SAV=$(readlink -f "$2")
else
    SAV="${ROM%.*}.sav"
fi

# ---------------------------------------------------------------- the image --
if ! $PODMAN image exists "$IMAGE"; then
    echo "building $IMAGE ..."
    $PODMAN build -t "$IMAGE" -f "$HERE/Containerfile.emu" "$HERE"
fi

# ------------------------------------------------------------ the scratch dir --
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$ROM" "$WORK/"
BASE=$(basename "$ROM")
if [ -f "$SAV" ]; then
    # Named after the ROM's stem whatever the source file was called: that is
    # the only name the emulator looks for.
    cp "$SAV" "$WORK/${BASE%.*}.sav"
    echo "save:  $(basename "$SAV")  ($(stat -c%s "$SAV") bytes)  md5 $(md5sum "$SAV" | cut -d' ' -f1)"
else
    echo "save:  none found -- the game will boot to an empty file list"
fi
echo "rom:   $BASE  ($(stat -c%s "$ROM") bytes)"

# ------------------------------------------------------------------- the X11 --
# Two things are needed to let a container draw on this desktop, and both are
# non-obvious enough that getting either wrong looks like the emulator failing.
#
# 1. SELINUX. The X socket is labelled user_tmp_t and a container runs as
#    container_t, which is denied write on it:
#
#      AVC avc: denied { write } for comm="mgba" name="X0"
#        scontext=...:container_t tcontext=...:user_tmp_t tclass=sock_file
#
#    Confirm with `ausearch -m avc -ts recent`. --security-opt label=disable is
#    the per-container fix; nothing system-wide is changed and no boolean is
#    set. Symptom without it: "unable to open display" and, from a shell in the
#    container, Permission denied listing /tmp/.X11-unix.
#
# 2. THE COOKIE. $XAUTHORITY holds an entry tied to this machine's hostname,
#    which the container does not share, so the cookie does not match and the
#    server refuses the connection. Rewriting the family to FamilyWild (ffff)
#    makes it host-independent. This copy is ours; the real cookie is untouched
#    and `xhost` is never called, so the desktop's access control is unchanged.
if [ -z "${DISPLAY:-}" ]; then
    echo "DISPLAY is not set; nothing to draw on" >&2; exit 1
fi
COOKIE="$WORK/xauth"
: > "$COOKIE"
xauth nlist "$DISPLAY" | sed -e 's/^..../ffff/' | xauth -f "$COOKIE" nmerge -
chmod 644 "$COOKIE"

# ------------------------------------------------------------------ play it --
# XDG_RUNTIME_DIR: without it mGBA prints "XDG_RUNTIME_DIR is invalid or not
# set" and SDL has nowhere to put its runtime files.
# SDL_AUDIODRIVER=dummy: there is no sound device in the container and ALSA
# otherwise buries every real message under a screenful of its own.
exec $PODMAN run --rm -i --security-opt label=disable \
    -e DISPLAY="$DISPLAY" -e XAUTHORITY=/work/xauth \
    -e XDG_RUNTIME_DIR=/tmp/xdg -e SDL_AUDIODRIVER=dummy \
    -v /tmp/.X11-unix:/tmp/.X11-unix \
    -v "$WORK":/work \
    --userns=keep-id \
    "$IMAGE" /usr/games/mgba --scale "$MGBA_SCALE" "/work/$BASE"
