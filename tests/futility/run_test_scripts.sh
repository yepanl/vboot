#!/bin/bash -eu
# Copyright 2013 The Chromium OS Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Load common constants and variables.
SCRIPTDIR=$(dirname $(readlink -f "$0"))
. "$SCRIPTDIR/common.sh"

# Mandatory arg is the directory where futility is installed.
[ -z "${1:-}" ] && error "Directory argument is required"
BINDIR="$1"
shift

FUTILITY="$BINDIR/futility"


# The Makefile should export the $BUILD directory, but if it's not just warn
# and guess (mostly so we can run the script manually).
if [ -z "${BUILD:-}" ]; then
  BUILD=$(dirname "${BINDIR}")
  yellow "Assuming \$BUILD=$BUILD"
fi
OUTDIR="${BUILD}/tests/futility_test_results"
[ -d "$OUTDIR" ] || mkdir -p "$OUTDIR"


# Let each test know where to find things...
export FUTILITY
export SCRIPTDIR
export OUTDIR

# These are the scripts to run. Binaries are invoked directly by the Makefile.
TESTS="
${SCRIPTDIR}/test_main.sh
${SCRIPTDIR}/test_dump_fmap.sh
${SCRIPTDIR}/test_gbb_utility.sh
"


# Get ready...
pass=0
progs=0

##############################################################################
# Invoke the scripts that test the builtin functions.

echo "-- builtin --"
for i in $TESTS; do
  j=${i##*/}

  : $(( progs++ ))

  echo -n "$j ... "
  rm -f "${OUTDIR}/$j."*
  rc=$("$i" "$FUTILITY" 1>"${OUTDIR}/$j.stdout" \
       2>"${OUTDIR}/$j.stderr" || echo "$?")
  echo "${rc:-0}" > "${OUTDIR}/$j.return"
  if [ ! "$rc" ]; then
    green "passed"
    : $(( pass++ ))
    rm -f ${OUTDIR}/$j.{stdout,stderr,return}
  else
    red "failed"
  fi

done

##############################################################################
# How'd we do?

if [ "$pass" -eq "$progs" ]; then
  green "Success: $pass / $progs passed"
  exit 0
fi

red "FAIL: $pass / $progs passed"
exit 1
