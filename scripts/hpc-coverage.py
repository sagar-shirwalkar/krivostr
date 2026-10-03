#!/usr/bin/env python3
"""Report Haskell test coverage from the HTML index `stack test --coverage` writes.

Why this exists instead of `hpc report`:

  stack --coverage writes a .tix file and the HTML dashboard, but it does not
  leave the .mix files that hpc needs to resolve a module's source, so every
  invocation dies with

      hpc-ghc-9.10.3: can not find krivostr-client-...-spec/Krivostr.Bridge in ./.hpc

  `hpc report --all` and `hpc report --coverage` are not options hpc 0.7 has at
  all, so they only print the usage text. The dashboard carries the same
  per-module covered/total counts, so the totals are summed from there.

Usage:
  scripts/hpc-coverage.py [--index PATH] [--quiet]

  --quiet   print only "covered total percent", for the threshold check.

Exit status is 0 when an index was found and parsed, 1 otherwise, so a missing
report is never mistaken for good coverage.
"""

from __future__ import annotations

import argparse
import html
import re
import sys
from pathlib import Path

# One dashboard row per module: the name cell links to <pkg>/<Module>.hs.html and
# is followed by "%" then "covered/total", repeated once per category
# (top level definitions, alternatives, expressions).
ROW_RE = re.compile(r"<tr>(.*?)</tr>", re.S)
MODULE_ROW = ".hs.html"
NAME_RE = re.compile(r'<a href="[^"]+\.hs\.html">([^<]+)</a>')
PACKAGE_RE = re.compile(r"^([a-z][a-z-]*?)-\d+\.\d+\.\d+\.\d+-[A-Za-z0-9]+-")
FRACTION_RE = re.compile(r"(\d+)\s*/\s*(\d+)")


def strip_tags(fragment: str) -> str:
    text = html.unescape(re.sub(r"<[^>]+>", " ", fragment))
    return re.sub(r"\s+", " ", text.replace("\xa0", " ")).strip()


def find_index(explicit: str | None) -> Path:
    if explicit:
        path = Path(explicit)
        if not path.is_file():
            sys.exit(f"no coverage index at {path}")
        return path

    # The combined index is the union of every test suite, so it is the one to
    # gate on. Sorted by mtime: a package rebuild leaves stale per-suite
    # dashboards behind, and the newest combined one is the current run.
    # stack puts it at hpc/combined/all, but a per-package hpc/<pkg>/combined/all
    # has shown up too, so both layouts are collected.
    root = Path(".stack-work/install")
    patterns = ("*/**/hpc/combined/all/hpc_index.html", "*/**/hpc/*/combined/all/hpc_index.html")
    candidates: list[Path] = []
    for pattern in patterns:
        candidates.extend(root.glob(pattern))
    candidates.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    if not candidates:
        sys.exit(
            "no coverage index found under .stack-work; run `stack test --coverage` first"
        )
    return candidates[0]


def parse(index: Path) -> tuple[list[tuple[str, int, int]], int, int]:
    """Return per-module (label, covered, total) plus the overall sums.

    Counts add up every category in a row, not just the first, so the total
    reflects the same work `hpc report` would have summarised.
    """
    rows = ROW_RE.findall(index.read_text(encoding="utf-8", errors="replace"))
    modules: list[tuple[str, int, int]] = []
    covered_total = statements_total = 0

    for row in rows:
        if MODULE_ROW not in row:
            continue
        flat = strip_tags(row)
        counts = FRACTION_RE.findall(flat)
        name_match = NAME_RE.search(row)
        if not counts or not name_match:
            continue
        name = name_match.group(1)
        covered = sum(int(c) for c, _ in counts)
        total = sum(int(t) for _, t in counts)
        if total == 0:
            continue
        modules.append((name, covered, total))
        covered_total += covered
        statements_total += total

    if not modules:
        sys.exit(f"{index} has no module rows; was it written by this script's hpc?")
    return label_packages(modules), covered_total, statements_total


def label_packages(modules: list[tuple[str, int, int]]) -> list[tuple[str, int, int]]:
    """Trim the package directory off module names, then re-add it where needed.

    The dashboard links each module as <pkg>/<Module>, where the package directory
    carries a build hash (krivostr-core-0.2.0.0-AbCdEf-spec). Names that are
    unique after trimming stay short; the repeats, such as each package's Main,
    get the package name back so the rows can be told apart.
    """
    short = [name.split("/")[-1] for name, _, _ in modules]
    seen: dict[str, int] = {}
    for name in short:
        seen[name] = seen.get(name, 0) + 1

    labelled = []
    for (name, covered, total), module in zip(modules, short):
        if seen[module] > 1:
            match = PACKAGE_RE.match(name)
            package = match.group(1) if match else name.split("/")[0]
            module = f"{module} ({package})"
        labelled.append((module, covered, total))
    return labelled


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", help="path to an hpc_index.html dashboard")
    parser.add_argument(
        "--quiet", action="store_true", help="print only covered/total/percent"
    )
    args = parser.parse_args()

    index = find_index(args.index)
    modules, covered, total = parse(index)
    percent = 100.0 * covered / total

    if args.quiet:
        print(f"{covered} {total} {percent:.1f}")
        return 0

    print(f"coverage index: {index}")
    width = max(len(name) for name, _, _ in modules)
    print(f"{'module'.ljust(width)}   covered / total")
    for name, mod_covered, mod_total in sorted(modules, key=lambda m: m[1] / m[2]):
        pct = 100.0 * mod_covered / mod_total
        print(f"{name.ljust(width)}   {mod_covered:>5} / {mod_total:<5}  {pct:5.1f}%")
    print(f"{'TOTAL'.ljust(width)}   {covered:>5} / {total:<5}  {percent:5.1f}%")
    return 0


if __name__ == "__main__":
    sys.exit(main())
