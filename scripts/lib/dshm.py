"""Shared helpers for scripts/plan, scripts/status and scripts/slice-env.

Stdlib only. Reads PLAN.md, ARCHITECTURE.md and scripts/resources.tsv, and knows the repo layout:
the main checkout (branch `main`) and the slice worktrees.
"""

import datetime
import os
import re
import subprocess
from pathlib import Path

STATUSES = ("todo", "doing", "blocked", "review", "done")
ACTIVE = ("todo", "doing", "blocked")          # a slice in these states holds its resources
SLICE_ID_RE = re.compile(r"^(T|X|S|M)\d+$")
REGISTRY = "scripts/resources.tsv"
REGISTRY_COLUMNS = ("id", "branch", "slot", "bridge", "web", "bridge2", "web2", "sim", "home",
                    "decisions", "assigned")

# WORKFLOW.md §6: slot k uses bridge 47810+k and web 3283+k; a second host adds 30.
BRIDGE_BASE, WEB_BASE, SECOND_OFFSET, MAX_SLOT = 47810, 3283, 30, 29
DECISION_BLOCK = 3


class PlanError(Exception):
    pass


def git(*args, cwd=None, check=True):
    r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise PlanError(f"git {' '.join(args)}: {r.stderr.strip()}")
    return r.stdout.strip()


def toplevel():
    return Path(git("rev-parse", "--show-toplevel"))


def main_checkout():
    """The checkout of the main repository (the parent of the common .git directory)."""
    common = Path(git("rev-parse", "--path-format=absolute", "--git-common-dir"))
    return common.parent


def branch():
    return git("rev-parse", "--abbrev-ref", "HEAD")


def today():
    return datetime.date.today().isoformat()


def check_id(sid):
    if not SLICE_ID_RE.match(sid or ""):
        raise PlanError(f"not a slice ID: {sid!r} (T0, X2, S14, …)")
    return sid


def read_main_file(path):
    """A file as committed on main (works from any worktree)."""
    return git("show", f"main:{path}")


# ---------------------------------------------------------------- PLAN.md

def split_lines(text):
    return text.split("\n")


def section_bounds(lines, heading_prefix):
    """(start, end) line indexes of the '## …' section whose heading starts with heading_prefix.
    end is the index of the next '## ' heading (or len)."""
    start = None
    for i, line in enumerate(lines):
        if start is None and line.startswith(heading_prefix):
            start = i
        elif start is not None and line.startswith("## "):
            return start, i
    if start is None:
        raise PlanError(f"PLAN.md: no section '{heading_prefix}'")
    return start, len(lines)


def status_table(lines):
    """§0 rows: list of (line index, dict with id, status, branch, updated, next)."""
    s, e = section_bounds(lines, "## 0. Status")
    rows = []
    for i in range(s, e):
        cells = table_cells(lines[i])
        if cells and SLICE_ID_RE.match(cells[0]) and len(cells) == 5:
            rows.append((i, dict(zip(("id", "status", "branch", "updated", "next"), cells))))
    return rows


def table_cells(line):
    if not line.startswith("|") or line.startswith("|---"):
        return None
    return [c.strip() for c in line.strip().strip("|").split("|")]


def format_row(cells):
    return "| " + " | ".join(cells) + " |"


def statuses(lines):
    return {r["id"]: r["status"] for _, r in status_table(lines)}


def slice_bounds(lines, sid):
    """(start, end) of '### <ID> · …' up to the next '### ' or '## ' heading."""
    start = None
    for i, line in enumerate(lines):
        if start is None and line.startswith(f"### {sid} ·"):
            start = i
        elif start is not None and (line.startswith("### ") or line.startswith("## ")):
            return start, i
    if start is None:
        raise PlanError(f"PLAN.md: no slice section '### {sid} ·'")
    return start, len(lines)


ITEM_RE = re.compile(r"^- \[(?P<box>[ xX])\] \[(?P<tier>auto|ui|human)\] (?P<desc>.*?)"
                     r"(?:\s+—\s+Evidence:(?P<ev>.*))?\s*$")


def items(lines, sid):
    s, e = slice_bounds(lines, sid)
    out = []
    for i in range(s, e):
        m = ITEM_RE.match(lines[i])
        if m:
            out.append((i, m))
    return out


# ---------------------------------------------------------------- ARCHITECTURE.md

D_ROW_RE = re.compile(r"^\| D(\d+) \|")


def decision_numbers(text):
    return {int(m.group(1)) for line in text.split("\n") if (m := D_ROW_RE.match(line))}


def decision_rows(text):
    return {int(m.group(1)): line for line in text.split("\n") if (m := D_ROW_RE.match(line))}


# ---------------------------------------------------------------- scripts/resources.tsv

def parse_registry(text):
    rows = []
    for line in text.split("\n"):
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if cells[0] == "id":
            continue
        if len(cells) != len(REGISTRY_COLUMNS):
            raise PlanError(f"{REGISTRY}: bad row: {line!r}")
        rows.append(dict(zip(REGISTRY_COLUMNS, cells)))
    return rows


def decision_range(text):
    """'D60-D62' -> (60, 62); 'D56' -> (56, 56); '—' -> None."""
    m = re.match(r"^D(\d+)(?:-D(\d+))?$", text or "")
    if not m:
        return None
    a = int(m.group(1))
    return a, int(m.group(2) or a)


def expand_home(path):
    return os.path.expanduser(path)
