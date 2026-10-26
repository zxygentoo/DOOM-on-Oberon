#!/usr/bin/env bash
# check_prereqs.sh — everything the build needs, one line each: what it is,
# the make targets that need it, and how to get it when it's missing. The OCaml
# packages themselves come from opam (`opam install --deps-only .`, see
# dune-project); this covers the rest — submodules, the switches, the gcc
# multilib, SDL2, the GNU tools. Exits 1 if a prerequisite of the default
# targets (blob, dsk, test, golden) is missing; ref/run/sim ones only warn.
#   make prereqs   (SWITCH= / OXSWITCH= as for every other target)
set -u
cd "$(dirname "$0")/.."
SWITCH=${SWITCH:-default}
OXSWITCH=${OXSWITCH:-5.2.0+ox}
HC=v0.18~preview.130.106+341 # sim/dune-project's hardcaml pin
fail=0

# report <req|opt> <label> <hint> <command...>: run the probe, print the verdict
report() {
  local need=$1 label=$2 hint=$3
  shift 3
  if "$@" >/dev/null 2>&1; then
    printf '  ok    %s\n' "$label"
  elif [ "$need" = req ]; then
    printf '  MISS  %s\n        -> %s\n' "$label" "$hint"
    fail=1
  else
    printf '  skip  %s\n        -> %s\n' "$label" "$hint"
  fi
}
has_switch() { opam switch list --short 2>/dev/null | grep -qxF "$1"; }
# pkg_is <switch> <package> <version|any>: installed (at that version)
pkg_is() {
  local v
  v=$(opam list --switch "$1" --installed --short --columns=version "$2" 2>/dev/null)
  [ -n "$v" ] && { [ "$3" = any ] || [ "$v" = "$3" ]; }
}
m32_links() {
  local t
  t=$(mktemp)
  printf 'int main(void) { return 0; }\n' | gcc -m32 -x c - -o "$t"
  local st=$?
  rm -f "$t"
  return $st
}

echo "host"
report req "x86-64 Linux (the only tested host: glibc headers, gcc -m32)" \
  "other hosts are untested" \
  test "$(uname -sm)" = "Linux x86_64"
report req "submodules initialised [everything]" \
  "git submodule update --init --recursive" \
  test -f vendor/doomgeneric/doomgeneric/Makefile \
  -a -f vendor/oberon-risc-hardcaml/vendor/oberon-risc-emu-ocaml/lib/risc5_isa.ml
report req "gcc with 32-bit multilib [test golden]" \
  "gcc-multilib (Debian/Ubuntu), glibc-devel.i686 + libgcc.i686 (Fedora)" \
  m32_links
report req "curl + md5sum [wad]" "install curl and coreutils" \
  sh -c 'command -v curl && command -v md5sum'
report req "GNU patch + GNU sed [dsk]" "install patch and GNU sed" \
  sh -c 'patch --version | grep -q GNU && sed --version | grep -q GNU'
report opt "sdl2-config [ref run]" "libsdl2-dev (Debian/Ubuntu), SDL2-devel (Fedora)" \
  command -v sdl2-config

echo "opam switch '$SWITCH' (override: make SWITCH=...)"
report req "opam" "https://opam.ocaml.org/doc/Install.html" command -v opam
report req "the switch exists" "opam switch create $SWITCH 5.3.0" has_switch "$SWITCH"
report req "goblint-cil 2.1.0 [blob test]" \
  "opam install --switch $SWITCH --deps-only ." pkg_is "$SWITCH" goblint-cil 2.1.0
report req "crunch [dsk]" \
  "opam install --switch $SWITCH --deps-only ." pkg_is "$SWITCH" crunch any
report opt "tsdl + imagelib [run]" \
  "opam install --switch $SWITCH tsdl imagelib" \
  sh -c "opam list --switch '$SWITCH' --installed --short tsdl imagelib 2>/dev/null | wc -l | grep -qx 2"

echo "opam switch '$OXSWITCH' (override: make OXSWITCH=...)"
report opt "the switch exists [sim]" \
  "opam switch create $OXSWITCH --repos ox=git+https://github.com/oxcaml/opam-repository.git,default" \
  has_switch "$OXSWITCH"
report opt "hardcaml $HC [sim]" \
  "opam install --switch $OXSWITCH --deps-only ./sim" pkg_is "$OXSWITCH" hardcaml "$HC"

[ $fail -eq 0 ] && echo "all required prerequisites present" \
  || echo "missing prerequisites (MISS above)"
exit $fail
