#!/bin/bash
# **THE OBSERVATORY WATCHING DOG PARK, TWO KERNELS, JUDGED** (metal-vmm QUEUE
# 228.3): observatory.elf and dogpark.elf on metal-vmm's PAIR mode, both
# sleeping between polls, so ten minutes of their time take about a second of
# ours.
#
#   tools/pair.sh
#
# - **unhurt**: ten polls a minute apart, every line `ok 200`, its commit Dog
#   Park's own (`git rev-parse --short HEAD` in ../dog-park, the commit
#   dogpark.elf was built from), and one start throughout (no restart line);
# - **Dog Park silent for a stretch**: nothing it sends arrives from 180 s to
#   300 s of its time (metal-vmm's WIRE_SILENT_S), across polls 4 and 5:
#   those two `no_arp`, the rest `ok`, and the Observatory polls on.
#
# Needs: KVM, metal-vmm, zig-metal-unikernel, dog-park and zig-webbox beside
# this checkout; observatory.elf (`zig build metal`) and dogpark.elf (`zig
# build metal` in ../dog-park); sgdisk, mkfs.vfat and mtools. Exit 0 when
# every check holds; 1 otherwise, naming each; 2 when it cannot run.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPOS="$(dirname "$HERE")"
VMM="$REPOS/metal-vmm/zig-out/bin/metal-vmm"
OBS="$HERE/zig-out/bin/observatory.elf"
DOG="$REPOS/dog-park/zig-out/bin/dogpark.elf"
WORK="${OUT:-$HOME/build/observatory/pair}"
for f in "$VMM" "$OBS" "$DOG"; do
    [ -f "$f" ] || { echo "pair.sh: NOT RUN: no $f"; exit 2; }
done
[ -e /dev/kvm ] || { echo "pair.sh: NOT RUN: no /dev/kvm"; exit 2; }
for t in sgdisk mkfs.vfat mcopy mmd; do
    command -v $t > /dev/null || { echo "pair.sh: NOT RUN: no $t"; exit 2; }
done
dog_commit=$(git -C "$REPOS/dog-park" rev-parse --short HEAD) || { echo "pair.sh: NOT RUN: no commit in ../dog-park"; exit 2; }
mkdir -p "$WORK"
failed=()
began=$SECONDS
fail() { echo "  FAIL $1: $2"; failed+=("$1"); }

# A GPT disk of one FAT16 partition, as Dog Park's QEMU gate makes one.
PART_FIRST=2048
PART=$((PART_FIRST * 512))
# disk <file> [<dir on the host> <name on the disk>]...
disk() {
    local img=$1; shift
    rm -f "$img"
    truncate -s 64M "$img"
    sgdisk -o -n "1:$PART_FIRST:0" -t 1:0700 "$img" > /dev/null || { echo "pair.sh: NOT RUN: sgdisk"; exit 2; }
    local last
    last=$(sgdisk -i 1 "$img" | sed -n 's/^Last sector: \([0-9]*\).*/\1/p')
    # Its warning that the partition's count differs from the image's size
    # is the GPT's own sectors at the end; any failure is said whole.
    local said
    said=$(mkfs.vfat -F 16 -S 512 --offset "$PART_FIRST" "$img" $(((last - PART_FIRST + 1) / 2)) 2>&1) || { echo "pair.sh: NOT RUN: mkfs.vfat: $said"; exit 2; }
    while [ $# -gt 0 ]; do
        mcopy -s -o -i "$img@@$PART" "$1" "::/$2" || { echo "pair.sh: NOT RUN: mcopy $1"; exit 2; }
        shift 2
    done
}

# watch <tag> [VAR=value ...]: Dog Park serving, the Observatory polling its
# /version every 60 s, for ten minutes of both machines' time. Sets code and
# outcomes (each line's outcome word, in order).
watch() {
    local tag=$1; shift
    disk "$WORK/$tag.dog" "$REPOS/dog-park/solo" solo
    mkdir -p "$WORK/$tag.data"
    printf 'target = 10.0.2.15:80 /version\ninterval_s = 60\n' > "$WORK/$tag.data/observatory.conf"
    disk "$WORK/$tag.obs" "$WORK/$tag.data" data
    env "$@" TRANSPORT=pci GUEST_S=600 WIRE_LATENCY_US=1000 PAIR="$OBS" PAIR_DISK="$WORK/$tag.obs" \
        PAIR_OUT="$WORK/$tag.obs.out" PAIR_CLIENT_TRANSPORT=pci \
        timeout 120 "$VMM" "$DOG" "$WORK/$tag.dog" > "$WORK/$tag.dog.out" 2> "$WORK/$tag.err"
    code=$?
    rm -f "$WORK/$tag.polls"
    mcopy -o -i "$WORK/$tag.obs@@$PART" ::data/polls.txt "$WORK/$tag.polls" 2> /dev/null
    touch "$WORK/$tag.polls"
    outcomes=$(awk '{print $2}' "$WORK/$tag.polls" | tr '\n' ' ')
}

watched() {
    [ "$code" = 0 ] && grep -q "run 600 s of its own time, as GUEST_S asked" "$WORK/$1.err"
}

# ── unhurt ──────────────────────────────────────────────────────────────────
watch unhurt
if ! watched unhurt; then
    fail unhurt "the pair did not end on GUEST_S (exit $code): $(tail -1 "$WORK/unhurt.err")"
elif [ "$outcomes" != "ok ok ok ok ok ok ok ok ok ok " ]; then
    fail unhurt "the ten polls: $outcomes (want ten ok): $(head -3 "$WORK/unhurt.polls" | tr '\n' ' ')"
elif [ "$(awk '{print $5}' "$WORK/unhurt.polls" | sort -u)" != "$dog_commit" ]; then
    fail unhurt "the commits said: $(awk '{print $5}' "$WORK/unhurt.polls" | sort -u | tr '\n' ' ')(want Dog Park's $dog_commit)"
elif [ "$(awk '{print $7}' "$WORK/unhurt.polls" | sort -u | wc -l)" != 1 ] || grep -q restarted "$WORK/unhurt.polls"; then
    fail unhurt "more than one start, or a restart line: $(awk '{print $7}' "$WORK/unhurt.polls" | sort -u | tr '\n' ' ')"
else
    echo "  unhurt: ten polls in ten minutes, each ok, Dog Park's commit $dog_commit, one start"
fi

# ── Dog Park silent for a stretch ───────────────────────────────────────────
watch silent WIRE_SILENT_S=180-300
if ! watched silent; then
    fail silent "the pair did not end on GUEST_S (exit $code): $(tail -1 "$WORK/silent.err")"
elif [ "$outcomes" != "ok ok ok no_arp no_arp ok ok ok ok ok " ]; then
    fail silent "the ten polls: $outcomes (want the 4th and 5th no_arp, the rest ok)"
else
    echo "  silent: Dog Park silent from 180 s to 300 s, polls 4 and 5 no_arp, the rest ok"
fi

echo "time: $((SECONDS - began)) s"
if [ ${#failed[@]} -gt 0 ]; then
    echo "PAIR: FAIL (${failed[*]})"
    exit 1
fi
echo "PAIR: PASS"
