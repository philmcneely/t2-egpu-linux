#!/bin/bash
# Runs the egpu-init tests in an Ubuntu 24.04 container (the scripts need GNU coreutils).
#   tests/run.sh            from a Mac or any Docker host
#   tests/run.sh --inside   already on Linux
cd "$(dirname "$0")/.." || exit 1
if [ "$1" != "--inside" ]; then
	exec docker run --rm -v "$PWD":/repo -w /repo ubuntu:24.04 bash tests/run.sh --inside
fi
rc=0
for t in tests/test_*.sh; do
	echo "== $t"
	bash "$t" || rc=1
done
exit $rc
