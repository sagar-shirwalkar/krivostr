#!/bin/sh
# Fail when test coverage is below the threshold in .hpc-threshold.
#
# The Makefile used to claim "HPC enforces 80%", but nothing read that file:
# `stack test --coverage` and `hpc report` print numbers and stop. This is the
# check that makes the number mean something, so that a drop in coverage fails
# the build instead of waiting to be noticed in a report.
#
# The number comes from scripts/hpc-coverage.py rather than `hpc report`: stack
# writes the HTML dashboard but no .mix files, so hpc cannot resolve a module
# and dies before printing a total. See that script for the details.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
threshold_file="$root/.hpc-threshold"

if [ ! -f "$threshold_file" ]; then
	echo "no .hpc-threshold file: nothing to enforce" >&2
	exit 0
fi

threshold=$(sed -n 's/^min:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$threshold_file")
if [ -z "$threshold" ]; then
	echo ".hpc-threshold has no 'min: N' line" >&2
	exit 1
fi

# Prints "covered total percent"; anything else means the report is unreadable.
set -- $("$root/scripts/hpc-coverage.py" --quiet)
if [ $# -ne 3 ]; then
	echo "could not read a coverage total from scripts/hpc-coverage.py" >&2
	exit 1
fi
covered=$1
total=$2
actual=${3%%.*}

echo "coverage $actual% ($covered of $total, threshold $threshold%)"
if [ "$actual" -lt "$threshold" ]; then
	echo "::error::coverage $actual% is below the $threshold% threshold" >&2
	exit 1
fi
