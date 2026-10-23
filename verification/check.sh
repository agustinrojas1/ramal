#!/bin/sh
# Runs every check under verification/: the Bend proofs, then TLC on the TLA+ model. Each regression config must fail
# on the property it names, which shows the model still sees the bug its fix closed (or the known limit it documents).
#
#   verification/check.sh            # both; needs java and bend, see README.md
#   verification/check.sh tla        # only TLC
#   verification/check.sh bend       # only Bend; BEND_FLAGS=--verdict rechecks with the BendTT kernel (needs Lean)
#   TLA2TOOLS=/path/tla2tools.jar verification/check.sh
set -eu

here=$(cd "$(dirname "$0")" && pwd)
jar=${TLA2TOOLS:-$here/.tools/tla2tools.jar}
tlc="java -XX:+UseParallelGC -cp $jar tlc2.TLC -workers auto -cleanup -noGenerateSpecTE"

only=${1:-all}

if [ "$only" != tla ]; then
  echo "== Bend: overlay and merge laws"
  out=$(cd "$here/bend" && bend PROOF.bend ${BEND_FLAGS:-} 2>&1) || { echo "$out"; exit 1; }
  echo "$out"
  # bend exits 0 on a failed proof too; the verdict line is what counts.
  echo "$out" | grep -q "^ALL PROOFS CHECK" || exit 1
fi

[ "$only" = bend ] && exit 0

cd "$here/tla"
echo "== TLC: MC.cfg (every property holds)"
$tlc -config MC.cfg MCRamal.tla > tlc.out 2>&1 || { tail -60 tlc.out; exit 1; }
grep -E "^[0-9,]+ states generated|No error has been found" tlc.out

expect() {
  config=$1
  property=$2
  echo "== TLC: $config (must violate $property)"
  if $tlc -config "$config" MCRamal.tla > tlc.out 2>&1; then
    echo "expected $property to be violated, but every property held"
    exit 1
  fi
  grep -q "$property is violated" tlc.out || { tail -60 tlc.out; exit 1; }
  grep -E "is violated" tlc.out
}

expect bug-pending.cfg NoPhantomWrite
expect bug-overlay.cfg OverlayMatchesLog
expect bug-marker.cfg OneMerger
expect limit-node-crash.cfg NoClaimAfterCommit
expect limit-merger-crash.cfg NoClaimAfterCommit
rm -f tlc.out
echo "== all checks passed"
