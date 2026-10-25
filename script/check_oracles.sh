#!/usr/bin/env bash
# check_oracles.sh — the emulator oracle set (`make check`). One
# deterministic -timedemo demo1 run on each side of the differential:
#   host    the golden generator: plain gcc -m32 over the same patched DOOM
#           and THE SHIPPED libc/dither.c (make golden — no CIL, no doomcc);
#   target  doom.blob, every byte from our backend or the eDSL, on run_blob.
# Two verdicts:
#   pixels  the raw framebuffer at each gametic in TICS is bit-identical;
#   desync  both runs end the demo at exactly WANT gametics, the host
#           reference build's count — one gametic of drift anywhere in the
#           demo's 143 s of play changes it.
# Both sides are regenerated here, from one gametic list, so stale frames in
# _out/golden/ can't vouch for anything. Results land in _out/check/; exits 1
# on any disagreement.
set -euo pipefail
cd "$(dirname "$0")/.."
TICS=100,1000,2500,5000 # past the demo-start wipe: render <-> gametic is 1:1
WANT=5026
RUN_BLOB=$PWD/_build/default/bin/run_blob.exe
GOLDEN=$PWD/_out/golden/golden
D=_out/check
rm -rf "$D"
mkdir -p "$D"
cd "$D"
ln -s ../doom1.wad doom1.wad
# both runs end in DOOM's I_Error("timed N gametics ...") — the success path
count() { sed -n 's/.*timed \([0-9]*\) gametics.*/\1/p' "$1" | head -n 1; }

echo "check: host run (golden generator)"
GOLDEN_TICS=$TICS "$GOLDEN" >golden.log 2>&1 || true
echo "check: target run (doom.blob on run_blob — a few minutes)"
"$RUN_BLOB" -args "-timedemo demo1" -ticks 6000 -dump-at "$TICS" \
  ../doom.blob doom1.wad >uart.log 2>run_blob.log || true

fail=0
for g in ${TICS//,/ }; do
  f=$(printf 'g%05d.fbw' "$g")
  if [ ! -f "golden_$f" ] || [ ! -f "frame_$f" ]; then
    verdict=MISSING
    fail=1
  elif cmp -s "golden_$f" "frame_$f"; then
    verdict=identical
  else
    verdict=DIFFER
    fail=1
  fi
  printf '  pixels  gametic %-5d %s\n' "$g" "$verdict"
done
for side in host:golden.log target:uart.log; do
  n=$(count "${side#*:}")
  if [ "$n" = "$WANT" ]; then verdict=ok; else
    verdict="WANT $WANT"
    fail=1
  fi
  label=${n:+$n gametics}
  printf '  desync  %-6s %s  %s\n' "${side%%:*}" "${label:-no count line}" "$verdict"
done
if [ $fail -eq 0 ]; then echo "check: PASS"; else
  echo "check: FAIL (logs in $D/)"
fi
exit $fail
