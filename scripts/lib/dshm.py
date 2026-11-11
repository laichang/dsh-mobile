"""Shared helpers for scripts/plan, scripts/status and scripts/slice-env.

Stdlib only. Reads ARCHITECTURE.md and scripts/resources.tsv, and knows the repo layout:
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
SIM_UDID = re.compile(r"[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}")
REGISTRY = "scripts/resources.tsv"
REGISTRY_COLUMNS = ("id", "branch", "slot", "bridge", "web", "bridge2", "web2", "sim", "home",
                    "decisions", "assigned")

# Slot k uses bridge 47810+k and web 3283+k; a second host adds 30.
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


# ---------------------------------------------------------------- disk and leftovers of a slice

MIN_FREE_GB_DEFAULT = 30       # the floor of the guard in scripts/demo/lib.sh (DSHM_MIN_FREE_GB)


def min_free_gb():
    try:
        return int(os.environ.get("DSHM_MIN_FREE_GB", MIN_FREE_GB_DEFAULT))
    except ValueError:
        return MIN_FREE_GB_DEFAULT


def disk_free():
    """(free KB, mount point) of the volume that holds $HOME. DSHM_FREE_KB replaces the KB (tests)."""
    r = subprocess.run(["df", "-kP", os.path.expanduser("~")], capture_output=True, text=True)
    lines = r.stdout.strip().split("\n")
    cells = lines[-1].split() if len(lines) > 1 else []
    kb = int(cells[3]) if len(cells) >= 6 and cells[3].isdigit() else None
    mount = cells[5] if len(cells) >= 6 else "?"
    if os.environ.get("DSHM_FREE_KB"):
        kb = int(os.environ["DSHM_FREE_KB"])
    return kb, mount


def tmp_root():
    return Path(os.environ.get("DSHM_TMP_ROOT", "/tmp"))


def simulators():
    """All simulators: [dict(name, udid, state, size)]. [] when simctl is not there."""
    import json
    try:
        r = subprocess.run(["xcrun", "simctl", "list", "devices", "-j"], capture_output=True, text=True)
        data = json.loads(r.stdout) if r.returncode == 0 else {}
    except (OSError, ValueError):
        return []
    out = []
    for devs in data.get("devices", {}).values():
        for d in devs:
            out.append(dict(name=d.get("name", ""), udid=d.get("udid", ""), state=d.get("state", ""),
                            size=int(d.get("dataPathSize") or 0)))
    return out


def worktree_entries(cwd=None):
    """[dict(path, head, branch)] from git worktree list; branch is '' when detached."""
    out, cur = [], None
    for line in git("worktree", "list", "--porcelain", cwd=cwd).split("\n"):
        if line.startswith("worktree "):
            cur = dict(path=line[9:], head="", branch="")
            out.append(cur)
        elif cur is not None and line.startswith("HEAD "):
            cur["head"] = line[5:]
        elif cur is not None and line.startswith("branch refs/heads/"):
            cur["branch"] = line[18:]
    return out


def safe_slice_home(home):
    """The real path of a slice DSHM_HOME if it is inside ~/.dshm/ (not ~/.dshm itself, not the
    shared runtime), else None."""
    if not home:
        return None
    base = os.path.realpath(os.path.expanduser("~/.dshm"))
    path = os.path.realpath(os.path.expanduser(home))
    runtime = os.path.join(base, "runtime")
    if path == base or os.path.commonpath([base, path]) != base:
        return None
    if path == runtime or os.path.commonpath([runtime, path]) == runtime:
        return None
    return path
