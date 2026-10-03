#!/bin/sh
# Fail when test coverage is below the threshold in .hpc-threshold.
#
# The Makefile used to claim "HPC enforces 80%", but nothing read that file:
# `stack test --coverage` and `hpc report` print numbers and stop. This is the
# check that makes the number mean something, so that a drop in coverage fails
# the build instead of waiting to be noticed in a report.
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

# hpc's last line is the total, e.g. "72% (1234 of 1700 statements)".
total=$(hpc report --coverage | tail -1)
actual=$(printf '%s' "$total" | sed -n 's/^\([0-9][0-9]*\)%.*/\1/p')

if [ -z "$actual" ]; then
  echo "could not read a coverage total from hpc:" >&2
  echo "$total" >&2
  exit 1
fi

echo "coverage $actual% (threshold $threshold%)"
if [ "$actual" -lt "$threshold" ]; then
  echo "::error::coverage $actual% is below the $threshold% threshold" >&2
  exit 1
fi
