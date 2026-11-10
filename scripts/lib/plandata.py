"""The plan as data: plan/plan.json (the graph), plan/<ID>.json (the items), and verifier results.

  plan/plan.json   {"title", "nodes": [{"id", "kind", "title", "needs", "branch", and the state:
                    "status", "updated", "next", "merge", "why", "cuts", "not", "demo", "log"}],
                    "exit", "log", "pending"}
  plan/<ID>.json   {"id", "items": [{"tier", "text", "files", "screens", "passed": false}]}

The schema is scripts/lib/plan.schema.json. This module checks it (a small validator for the part
of JSON Schema that the file uses: no dependency) and the rules a schema cannot say: unique IDs,
the kind of each ID, known needs, no cycle, one plan/<ID>.json for each node.

`passed` in a plan/<ID>.json is always false. The value that counts is derived from the results
of `scripts/plan verify <ID>`: it checks out the head commit of the slice branch clean, runs the
`cmd:` evidence of each item there (and checks `commit:` pointers), and stores the commands and
their exit codes as a git note on that commit (ref refs/notes/dshm-verify, shared by all
worktrees). No command takes results from outside. A new commit has no results until verify runs
again: old results are stale. An item passes only with at least one `cmd:` pointer and every run
at exit 0. The results are advisory: anyone with a shell can write a note, so the merge step runs
verify again on the commit that it merges.

Used by scripts/plan (every command), scripts/check-plan (each change of plan/), scripts/brief,
scripts/review, scripts/slice-env and scripts/status.
"""

import datetime
import fnmatch
import importlib.util
import json
import os
import posixpath
import re
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
from importlib.machinery import SourceFileLoader
from pathlib import Path

PLAN_DIR = "plan"
PLAN_FILE = "plan/plan.json"
NOTES_REF = "refs/notes/dshm-verify"
SCHEMA_PATH = Path(__file__).resolve().with_name("plan.schema.json")
PREFIX = {"tracer": "T", "spike": "X", "slice": "S"}
SLICE_FILE_RE = re.compile(r"^plan/(?P<id>(T|X|S)\d+)\.json$")
STALE_DEPTH = 50                # how far back `passed` looks for stale results
VERIFIER = "scripts/plan verify"
TIMEOUT = int(os.environ.get("DSHM_VERIFY_TIMEOUT", "3600"))    # seconds, for each command


class DataError(Exception):
    pass


# ----------------------------------------------------------------------------------- schema

_schema = None


def schema():
    global _schema
    if _schema is None:
        _schema = json.loads(SCHEMA_PATH.read_text())
    return _schema


def _type_ok(value, t):
    if isinstance(t, list):
        return any(_type_ok(value, x) for x in t)
    return {
        "object": lambda v: isinstance(v, dict),
        "array": lambda v: isinstance(v, list),
        "string": lambda v: isinstance(v, str),
        "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
        "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
        "boolean": lambda v: isinstance(v, bool),
        "null": lambda v: v is None,
    }[t](value)


def validate(value, sch, where="$"):
    """Errors of value against sch (the keywords that plan.schema.json uses)."""
    if "$ref" in sch:
        name = sch["$ref"].removeprefix("#/$defs/")
        return validate(value, schema()["$defs"][name], where)
    errs = []
    if "type" in sch and not _type_ok(value, sch["type"]):
        return [f"{where}: must be {sch['type']}, not {json.dumps(value)[:40]}"]
    if "const" in sch and value != sch["const"]:
        errs.append(f"{where}: must be {json.dumps(sch['const'])}")
    if "enum" in sch and value not in sch["enum"]:
        errs.append(f"{where}: must be one of {', '.join(map(str, sch['enum']))}")
    if isinstance(value, str):
        if len(value) < sch.get("minLength", 0):
            errs.append(f"{where}: must not be empty")
        if "pattern" in sch and not re.search(sch["pattern"], value):
            errs.append(f"{where}: {value!r} does not match {sch['pattern']}")
    if isinstance(value, int) and not isinstance(value, bool) and value < sch.get("minimum", value):
        errs.append(f"{where}: must be {sch['minimum']} or more")
    if isinstance(value, list):
        if len(value) < sch.get("minItems", 0):
            errs.append(f"{where}: needs at least {sch['minItems']} entries")
        if sch.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            errs.append(f"{where}: has an entry two times")
        if "items" in sch:
            for i, v in enumerate(value):
                errs += validate(v, sch["items"], f"{where}[{i}]")
    if isinstance(value, dict):
        for k in sch.get("required", []):
            if k not in value:
                errs.append(f"{where}: {k} is missing")
        props = sch.get("properties", {})
        for k, v in value.items():
            if k in props:
                errs += validate(v, props[k], f"{where}.{k}")
            elif sch.get("additionalProperties") is False:
                errs.append(f"{where}: unknown field {k}")
    return errs


def check_against(value, defname, where):
    return validate(value, {"$ref": f"#/$defs/{defname}"}, where)


# ------------------------------------------------------------------------------------ graph

def graph_errors(plan):
    """Rules of plan/plan.json beyond the schema: IDs, kinds, branches, needs, cycles."""
    errs, ids = [], []
    for n in plan["nodes"]:
        if n["id"] in ids:
            errs.append(f"{PLAN_FILE}: {n['id']} is in the graph two times")
        ids.append(n["id"])
        if not n["id"].startswith(PREFIX[n["kind"]]):
            errs.append(f"{PLAN_FILE}: {n['id']} is a {n['kind']}, so its ID starts with {PREFIX[n['kind']]}")
        b = n["branch"]
        if b and not re.search(rf"(^|/){n['id'].lower()}(-|$)", b):
            errs.append(f"{PLAN_FILE}: the branch of {n['id']} must name it (claude/{n['id'].lower()}-…), not {b}")
    known = set(ids)
    for n in plan["nodes"]:
        for need in n["needs"]:
            if need == n["id"]:
                errs.append(f"{PLAN_FILE}: {n['id']} needs itself")
            elif need not in known:
                errs.append(f"{PLAN_FILE}: {n['id']} needs {need}, which is not in the graph")
    if not errs:
        cyc = find_cycle(plan)
        if cyc:
            errs.append(f"{PLAN_FILE}: the needs make a cycle: {' -> '.join(cyc)}")
    return errs


def find_cycle(plan):
    needs = {n["id"]: n["needs"] for n in plan["nodes"]}
    state, stack = {}, []

    def visit(v):
        state[v] = 1
        stack.append(v)
        for w in needs.get(v, []):
            if state.get(w) == 1:
                return stack[stack.index(w):] + [w]
            if w in needs and not state.get(w):
                c = visit(w)
                if c:
                    return c
        stack.pop()
        state[v] = 2
        return None

    for n in plan["nodes"]:
        if not state.get(n["id"]):
            c = visit(n["id"])
            if c:
                return c
    return None


def dag(plan):
    """The graph as JSON data: nodes, edges (need -> node), and a topological order (stable)."""
    errs = check_against(plan, "plan", PLAN_FILE)
    errs = errs or graph_errors(plan)
    if errs:
        raise DataError("\n".join(errs) + "\nNext: repair plan/ with scripts/plan (`scripts/plan lint` lists each error)")
    pos = {n["id"]: i for i, n in enumerate(plan["nodes"])}
    left = {n["id"]: set(n["needs"]) for n in plan["nodes"]}
    order = []
    while left:
        ready = sorted((i for i, ns in left.items() if not ns), key=pos.get)
        order.append(ready[0])
        del left[ready[0]]
        for ns in left.values():
            ns.discard(ready[0])
    return {
        "title": plan["title"],
        "nodes": plan["nodes"],
        "edges": [{"from": need, "to": n["id"]} for n in plan["nodes"] for need in n["needs"]],
        "order": order,
    }


# ------------------------------------------------------------------------------------ files

def tree_errors(files):
    """Errors of a plan/ tree. files: {repo-relative path: text} of everything under plan/."""
    if not files:
        return []
    errs, docs = [], {}
    for path, text in sorted(files.items()):
        if path != PLAN_FILE and not SLICE_FILE_RE.match(path):
            errs.append(f"{path}: plan/ holds only plan.json and <ID>.json")
            continue
        try:
            docs[path] = json.loads(text)
        except json.JSONDecodeError as e:
            errs.append(f"{path}: not JSON ({e})")
    plan = docs.pop(PLAN_FILE, None)
    if plan is None:
        if PLAN_FILE not in files:
            errs.append(f"{PLAN_FILE} is missing")
        return errs
    perr = check_against(plan, "plan", PLAN_FILE)
    errs += perr or graph_errors(plan)
    if not perr:
        errs += [f"{PLAN_FILE}: exit item {i + 1} is [{it['tier']}]; exit items are [human]"
                 for i, it in enumerate(plan.get("exit", [])) if it["tier"] != "human"]
    ids ={n["id"] for n in plan.get("nodes", []) if isinstance(n, dict) and "id" in n} if not perr else set()
    for path, doc in docs.items():
        fid = SLICE_FILE_RE.match(path)["id"]
        serr = check_against(doc, "slice", path)
        errs += serr
        if not serr and doc["id"] != fid:
            errs.append(f"{path}: id is {doc['id']}, the file name says {fid}")
        if not perr and fid not in ids:
            errs.append(f"{path}: {fid} is not a node of {PLAN_FILE}")
    for sid in sorted(ids):
        if f"plan/{sid}.json" not in files:
            errs.append(f"plan/{sid}.json is missing (each node has its items file)")
    return errs


def worktree_files(root):
    d = Path(root, PLAN_DIR)
    if not d.is_dir():
        return {}
    return {f"{PLAN_DIR}/{p.name}": p.read_text() for p in sorted(d.iterdir()) if p.is_file()}


def staged_files(root):
    """The plan/ files of the index (what a commit would hold)."""
    r = _git(root, "ls-files", "-z", "--cached", "--", PLAN_DIR)
    out = {}
    for path in filter(None, r.stdout.split("\0")):
        b = _git(root, "show", f":{path}")
        out[path] = b.stdout
    return out


def staged_errors(root):
    """For scripts/check-plan --staged."""
    return tree_errors(staged_files(root))


def load(root):
    files = worktree_files(root)
    if PLAN_FILE not in files:
        raise DataError(NO_PLAN)
    errs = tree_errors(files)
    if errs:
        raise DataError("\n".join(errs) + "\nNext: repair plan/ with scripts/plan (`scripts/plan lint` lists each error)")
    plan = json.loads(files[PLAN_FILE])
    items = {n["id"]: json.loads(files[f"plan/{n['id']}.json"])["items"] for n in plan["nodes"]}
    return plan, items


def load_plan(root):
    p = Path(root, PLAN_FILE)
    if not p.exists():
        raise DataError(NO_PLAN)
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        raise DataError(f"{PLAN_FILE}: not JSON ({e}). Next: `git checkout -- {PLAN_FILE}`, then change it with scripts/plan")


def committed_files(root, ref):
    """The plan/ files of a commit (what is committed, never an uncommitted edit)."""
    r = _git(root, "ls-tree", "-z", "--name-only", f"{ref}^{{commit}}", "--", f"{PLAN_DIR}/")
    if r.returncode != 0:
        raise DataError(f"{ref} is not a commit. Next: give a branch name or a commit (`git log --oneline`)")
    return {p: _git(root, "show", f"{ref}:{p}", check=True).stdout for p in filter(None, r.stdout.split("\0"))}


def load_at(root, ref):
    """plan.json and the items of each node, as the commit ref has them (checked)."""
    files = committed_files(root, ref)
    if PLAN_FILE not in files:
        raise DataError(f"{PLAN_FILE} does not exist at {ref}. Next: give a commit that has the plan (`git log --oneline -- {PLAN_FILE}`)")
    errs = tree_errors(files)
    if errs:
        raise DataError("\n".join(f"{e} (at {ref})" for e in errs) + f"\nNext: give a commit with a valid plan/, or repair plan/ at {ref} with scripts/plan")
    plan = json.loads(files[PLAN_FILE])
    items = {n["id"]: json.loads(files[f"plan/{n['id']}.json"])["items"] for n in plan["nodes"]}
    return plan, items


def node_at(root, ref, sid):
    """The node of sid in plan.json as committed at ref (its branch comes from there)."""
    r = _git(root, "show", f"{ref}:{PLAN_FILE}")
    if r.returncode != 0:
        raise DataError(f"{PLAN_FILE} does not exist at {ref}. Next: give a commit that has the plan (`git log --oneline -- {PLAN_FILE}`)")
    try:
        plan = json.loads(r.stdout)
    except json.JSONDecodeError as e:
        raise DataError(f"{PLAN_FILE} at {ref}: not JSON ({e}). Next: give a commit with a valid plan/")
    errs = check_against(plan, "plan", f"{PLAN_FILE} at {ref}")
    if errs:
        raise DataError("\n".join(errs) + "\nNext: repair plan/ with scripts/plan (`scripts/plan lint` lists each error)")
    node = next((n for n in plan["nodes"] if n["id"] == sid), None)
    if node is None:
        raise DataError(f"{sid} is not a node of {PLAN_FILE} at {ref}. Next: `scripts/plan dag` lists the IDs")
    return node


# ---------------------------------------------------------------------------------- results

def _git(root, *args, check=False, input=None):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise DataError(f"git {' '.join(args)} failed: {r.stderr.strip()}. Next: repair the git state that the message names, then run it again")
    return r


def branch_head(root, branch):
    if not branch:
        return None
    r = _git(root, "rev-parse", "-q", "--verify", f"refs/heads/{branch}^{{commit}}")
    return r.stdout.strip() if r.returncode == 0 else None


def note(root, commit):
    r = _git(root, "notes", f"--ref={NOTES_REF}", "show", commit)
    if r.returncode != 0:
        return {}
    try:
        data = json.loads(r.stdout)
    except json.JSONDecodeError:
        return {}
    return data if isinstance(data, dict) else {}


def results_for(root, sid, commit):
    """The results of `scripts/plan verify` for sid at commit, or None. A note in any other shape
    (no runs, another verifier, another commit) counts for nothing."""
    res = note(root, commit).get(sid)
    if (not isinstance(res, dict) or check_against(res, "results", "note") or res["commit"] != commit
            or res["verifier"] != VERIFIER):
        return None
    return res


def item_passed(r):
    """An item passed when its record has runs and each run exited 0 (not the flag alone)."""
    return bool(r.get("passed")) and bool(r.get("runs")) and all(x["exit"] == 0 for x in r["runs"])


def _store(root, commit, sid, results):
    data = note(root, commit)
    data[sid] = results
    _git(root, "notes", f"--ref={NOTES_REF}", "add", "-f", "-F", "-", commit, check=True,
         input=json.dumps(data, indent=2, ensure_ascii=False) + "\n")


def cmd_problem(argv, cwd):
    """Why argv[0] is not a cmd: pointer that verify runs, or None. It must be a repo-relative
    path with no symlink in it, inside the checkout, and an executable file of the commit."""
    if not argv:
        return "is empty"
    rel = Path(argv[0])
    if rel.is_absolute() or ".." in rel.parts:
        return "is not repo-relative"
    top, p = Path(cwd).resolve(), Path(cwd)
    for part in rel.parts:
        p = p / part
        if p.is_symlink():
            return f"goes through the symlink {p.relative_to(cwd)}"
    if not p.is_file() or not p.resolve().is_relative_to(top):
        return "is not a file of the checkout"
    mode = _git(cwd, "ls-tree", "HEAD", "--", rel.as_posix()).stdout.split()[:1]
    if mode != ["100755"]:
        return "is not an executable file of the commit"
    return None


def _run(cmd, cwd, logpath):
    """Run one cmd: pointer (a repo-relative executable of the commit and its arguments) in cwd."""
    argv = shlex.split(cmd)
    t0 = time.monotonic()
    why = cmd_problem(argv, cwd)
    if why:
        Path(logpath).write_text(f"verify: {cmd!r} {why}\n")
        return {"cmd": cmd, "exit": 127, "seconds": 0.0, "log": str(logpath)}
    exe = Path(cwd, argv[0])
    with open(logpath, "w") as log:
        try:
            r = subprocess.run([str(exe), *argv[1:]], cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                               stdin=subprocess.DEVNULL, timeout=TIMEOUT)
            code = r.returncode
        except subprocess.TimeoutExpired:
            log.write(f"\nverify: timed out after {TIMEOUT} s\n")
            code = 124
    return {"cmd": cmd, "exit": code, "seconds": round(time.monotonic() - t0, 1), "log": str(logpath)}


def _ancestor(root, ref, head):
    r = _git(root, "merge-base", "--is-ancestor", ref, head)
    return {"cmd": f"git merge-base --is-ancestor {ref} {head[:12]}", "exit": r.returncode,
            "seconds": 0.0, "log": ""}


def run_items(sid, items, wt, commit, say=print):
    """Run the evidence of items in the clean checkout wt of commit: the results of each item."""
    logs = Path(os.environ.get("DSHM_VERIFY_LOGS", "/tmp/dshm-verify"))
    logs.mkdir(parents=True, exist_ok=True)
    done, out = {}, []
    for i, it in enumerate(items):
        runs = []
        ptrs = [p.strip() for p in it.get("evidence", [])]
        cmds = [p[4:].strip() for p in ptrs if p.startswith("cmd:")]
        if it["tier"] != "human":
            for p in ptrs:
                if p.startswith("commit:"):
                    runs.append(_ancestor(wt, p[7:].strip(), commit))
            for c in cmds:
                if c not in done:
                    say(f"verify {sid} item {i}: {c}")
                    done[c] = _run(c, wt, logs / f"{sid}-{commit[:12]}-{len(done)}.log")
                runs.append(done[c])
        ok = bool(cmds) and all(r["exit"] == 0 for r in runs)
        out.append({"item": i, "passed": ok, "runs": runs})
    return out


def _results(sid, commit, out):
    return {"slice": sid, "commit": commit, "verifier": VERIFIER, "host": socket.gethostname(),
            "at": datetime.datetime.now().astimezone().isoformat(timespec="seconds"), "items": out}


class Checkout:
    """A clean detached checkout of commit in a temporary worktree, removed on exit."""
    def __init__(self, root, commit, name):
        self.root, self.commit = root, commit
        self.tmp = Path(tempfile.mkdtemp(prefix=f"dshm-{name}-"))
        self.path = self.tmp / "wt"

    def __enter__(self):
        _git(self.root, "worktree", "add", "-q", "--detach", str(self.path), self.commit, check=True)
        return self.path

    def __exit__(self, *exc):
        _git(self.root, "worktree", "remove", "--force", str(self.path))
        shutil.rmtree(self.tmp, ignore_errors=True)


def verify(root, sid, base="HEAD", say=print):
    """Run the evidence of each item of sid on a clean checkout of the head of its branch, and
    store what ran (commands, exit codes) as the results for that commit. The branch comes from
    plan.json as committed at base (not from an uncommitted edit). The only writer of results:
    no command takes results from outside."""
    node = node_at(root, base, sid)
    head = branch_head(root, node["branch"])
    if head is None:
        raise DataError(f"{sid} has no branch with a commit ({node['branch']}). Next: the slice owner commits on that branch, or the coordinator runs `scripts/plan assign {sid} --branch <branch>`")
    with Checkout(root, head, f"verify-{sid.lower()}") as wt:
        _, items = load(wt)
        if sid not in items:
            raise DataError(f"{sid} is not a node of {PLAN_FILE} at {head[:12]}. Next: the slice owner merges main into the branch")
        out = run_items(sid, items[sid], wt, head, say)
    results = _results(sid, head, out)
    _store(root, head, sid, results)
    return results


def derive(root, sid, base="HEAD"):
    """passed of each item of sid, from the verifier results for the head of its branch. The
    branch and the items come from the plan as committed at base, not from an uncommitted edit."""
    plan, items = load_at(root, base)
    node = next((n for n in plan["nodes"] if n["id"] == sid), None)
    if node is None:
        raise DataError(f"{sid} is not a node of {PLAN_FILE} at {base}. Next: `scripts/plan dag` lists the IDs")
    head = branch_head(root, node["branch"])
    if head:    # the items as the head commit has them: the ones that verify ran
        r = _git(root, "show", f"{head}:plan/{sid}.json")
        if r.returncode == 0:
            doc = json.loads(r.stdout)
            errs = check_against(doc, "slice", f"plan/{sid}.json at {head[:12]}")
            if errs:
                raise DataError("\n".join(errs) + "\nNext: repair plan/ with scripts/plan (`scripts/plan lint` lists each error)")
            items = {sid: doc["items"]}
    res = results_for(root, sid, head) if head else None
    by_item = {r["item"]: r for r in res["items"]} if res else {}
    out_items = []
    for i, it in enumerate(items[sid]):
        r = by_item.get(i, {})
        out_items.append({"item": i, "tier": it["tier"], "text": it["text"],
                          "passed": item_passed(r), "runs": r.get("runs", [])})
    stale = None
    if head and res is None:
        log = _git(root, "rev-list", f"--max-count={STALE_DEPTH}", head).stdout.split()
        stale = next((c for c in log[1:] if results_for(root, sid, c)), None)
    checked = [i for i in out_items if i["tier"] != "human"]
    return {
        "id": sid, "branch": node["branch"], "head": head,
        "verifier": res["verifier"] if res else None,
        "verified_at": res["at"] if res else None,
        "stale": stale,
        "passed": bool(res) and bool(checked) and all(i["passed"] for i in checked),
        "items": out_items,
    }


# ------------------------------------------------------------------------------------ merge

SELF_FILES = ("scripts/plan", "scripts/lib/plandata.py", "scripts/lib/plan.schema.json",
              "scripts/lib/dshm.py")


def same_as(root, ref, here):
    """True when the copies of the merge tools that run now (in the checkout `here`) are the
    ones committed at ref, byte for byte."""
    for f in SELF_FILES:
        want = _git(root, "rev-parse", "-q", "--verify", f"{ref}:{f}").stdout.strip()
        have = _git(root, "hash-object", "--", str(Path(here, f))).stdout.strip()
        if not want or want != have:
            return False
    return True


def _bare_items(items):
    return [{k: v for k, v in it.items() if k != "evidence"} for it in items]


def merge_items(base_items, head_items):
    """The items that the merge step checks: tier and text as the base has them (the branch
    may not change them), the evidence of the base, then the pointers that the branch adds."""
    if _bare_items(base_items) != _bare_items(head_items):
        raise DataError("the branch changed the items (tier, text, files or screens); "
                        "the merge step checks the items of the base. Next: the slice owner restores the "
                        "items and only adds evidence (scripts/plan evidence)")
    out = []
    for b, h in zip(base_items, head_items):
        ev = list(b.get("evidence", []))
        ev += [p for p in h.get("evidence", []) if p not in ev]
        out.append({**b, "evidence": ev})
    return out


def checked_out(root, branch):
    """The worktree that has branch checked out, or None."""
    wt = None
    for line in _git(root, "worktree", "list", "--porcelain").stdout.splitlines():
        if line.startswith("worktree "):
            wt = line[9:]
        elif line == f"branch refs/heads/{branch}":
            return wt
    return None


def _tree(root, commit):
    """{path: (mode, blob)} of every file of commit."""
    out = {}
    for line in _git(root, "ls-tree", "-r", "-z", commit, check=True).stdout.split("\0"):
        if line:
            meta, path = line.split("\t", 1)
            mode, _, blob = meta.split()
            out[path] = (mode, blob)
    return out


PATH_RE = re.compile(r"[A-Za-z0-9_.][A-Za-z0-9_./-]*")


def evidence_files(root, items, commits):
    """(direct, named): the files that the cmd: evidence of items names (each executable and
    each argument that is a file), and those plus each repo path that a text file among them
    names (one level). In the trees of commits."""
    trees = [_tree(root, c) for c in commits]
    known = lambda f: any(f in t for t in trees)
    direct = set()
    for it in items:
        if it["tier"] == "human":
            continue
        for ptr in it.get("evidence", []):
            if ptr.startswith("cmd:"):
                direct.update(a for a in shlex.split(ptr[4:].strip()) if known(a))
    named = set(direct)
    for f in direct:
        for c in commits:
            r = _git(root, "cat-file", "-p", f"{c}:{f}")
            if r.returncode == 0:
                for w in PATH_RE.findall(r.stdout):
                    parts = w.split("/")     # $ROOT/scripts/x names scripts/x
                    named.update(c for c in ("/".join(parts[i:]).lstrip("./") for i in range(len(parts)))
                                 if ("/" in c or "." in c) and known(c))
    return sorted(direct), sorted(named)


PROTECTED_EVIDENCE_DIRS = ("scripts/lib/",)


def protected_evidence(root, items, base, head):
    """The evidence files of the target that a slice may not change without review: each file
    that the evidence names (see evidence_files) and the target has; every file of the target in
    the directory of a file that a cmd: pointer names, and below it (a helper called as
    "$(dirname "$0")/x" is there; for a file at the top of the repo, only that file); and
    scripts/lib/. Conservative on purpose: it does not follow calls."""
    tb = _tree(root, base)
    direct, named = evidence_files(root, items, [base, head])
    prot = {f for f in named if f in tb}
    dirs = {posixpath.dirname(f) + "/" for f in direct if f in tb and posixpath.dirname(f)}
    dirs.update(PROTECTED_EVIDENCE_DIRS)
    prot.update(p for p in tb if any(p.startswith(d) for d in dirs))
    return prot, [f for f in named if f not in tb]


def evidence_changes(root, items, base, head):
    """(changed, new): protected evidence files that the branch changes or deletes (against the
    merge base), and evidence files that only the branch has."""
    fork = _git(root, "merge-base", base, head, check=True).stdout.strip()
    tf, th = _tree(root, fork), _tree(root, head)
    prot, new = protected_evidence(root, items, base, head)
    return sorted(f for f in prot if tf.get(f) != th.get(f)), new


def guard_patterns():
    """PROTECTED of scripts/check-plan (the copy next to this file): the guard files."""
    path = Path(__file__).resolve().parents[1] / "check-plan"
    loader = SourceFileLoader("check_plan", str(path))
    mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("check_plan", loader))
    loader.exec_module(mod)
    return mod.PROTECTED


def guard_changes(root, base, head):
    """The guard files that head changes since its merge base with base."""
    r = _git(root, "diff", "--name-only", f"{base}...{head}", check=True)
    pats = guard_patterns()
    return [f for f in r.stdout.splitlines() if any(fnmatch.fnmatch(f, p) for p in pats)]


def merge(root, sid, into, dry=False, allow=(), say=print):
    """The merge step. Merge the branch of sid into `into`, only if the checks pass on the merge
    commit itself. Inputs are the ID and the target branch, nothing else: no report, no earlier
    results. The branch and the items come from the plan as committed at the tip of `into`
    (the branch's own copy of the items may only add evidence). It makes the merge commit in a
    clean checkout of that tip, runs the evidence there, stores the results on the merge commit,
    and then moves `into` to it (fast-forward of the worktree that has `into` checked out, or a
    compare-and-swap of the ref). The caller (scripts/plan merge) makes sure that this code is
    the copy committed at the tip of `into`."""
    base = branch_head(root, into)
    if base is None:
        raise DataError(f"no branch {into}. Next: give an existing target branch, for example --into main")
    node = node_at(root, base, sid)
    head = branch_head(root, node["branch"])
    if head is None:
        raise DataError(f"{sid} has no branch with a commit ({node['branch']}, from {PLAN_FILE} at {into}). "
                        f"Next: the slice owner commits on {node['branch']}, or the coordinator runs "
                        f"`scripts/plan assign {sid} --branch <branch>`")
    guards = guard_changes(root, base, head)
    if guards:
        raise DataError(f"the slice changes guard files: {', '.join(guards)}. Next: the user reviews "
                        f"the guard diff and merges by hand with CHECK_PLAN_ALLOW=1")
    _, base_items = load_at(root, base)
    r = _git(root, "show", f"{head}:plan/{sid}.json")
    if r.returncode != 0:
        raise DataError(f"plan/{sid}.json does not exist at the head of {node['branch']}. Next: the slice owner merges main into the branch")
    head_doc = json.loads(r.stdout)
    errs = check_against(head_doc, "slice", f"plan/{sid}.json at {head[:12]}")
    if errs:
        raise DataError("\n".join(errs) + "\nNext: repair plan/ with scripts/plan (`scripts/plan lint` lists each error)")
    items = merge_items(base_items[sid], head_doc["items"])
    changed, new = evidence_changes(root, items, base, head)
    blocked = [f for f in changed if f not in allow]
    if blocked:
        raise DataError("evidence changed by the slice: a reviewer or the user must look at it:\n"
                        + "".join(f"  {f}\n" for f in blocked)
                        + "Next: after a reviewer has read that diff, the coordinator may pass "
                        + " ".join(f"--allow-changed-evidence {f}" for f in blocked))
    used = [f for f in allow if f in changed]
    summary = {"slice": sid, "into": into, "base": base, "branch": node["branch"], "head": head,
               "merge": None, "passed": False, "merged": False, "new_evidence": new,
               "allowed_changed_evidence": used, "items": []}
    msg = f"Merge {sid}: {node['title']}"
    if new:
        msg += "\n\nNew evidence, judged by the reviewer: " + ", ".join(new)
    if used:
        msg += "\n\n" + "".join(f"allow-changed-evidence: {f}\n" for f in used)
    with Checkout(root, base, f"merge-{sid.lower()}") as wt:
        m = _git(wt, "merge", "--no-ff", "--no-edit", "-m", msg, head)
        if m.returncode != 0:
            _git(wt, "merge", "--abort")
            raise DataError(f"the merge of {node['branch']} into {into} failed:\n{m.stdout}{m.stderr}\n"
                            f"Next: the slice owner merges {into} into {node['branch']} and resolves the conflicts")
        commit = _git(wt, "rev-parse", "HEAD", check=True).stdout.strip()
        if _git(wt, "status", "--porcelain").stdout.strip():
            raise DataError("the merge checkout is not clean after the merge. Next: check .gitignore for "
                            "files that the merge writes, then run it again")
        out = run_items(sid, items, wt, commit, say)
    _store(root, commit, sid, _results(sid, commit, out))
    checked = [o for o, it in zip(out, items) if it["tier"] != "human"]
    passed = bool(checked) and all(item_passed(o) for o in checked)
    summary.update(merge=commit, passed=passed, items=[
        {"item": o["item"], "tier": it["tier"], "text": it["text"], "passed": item_passed(o),
         "runs": [{"cmd": x["cmd"], "exit": x["exit"]} for x in o["runs"]]} for o, it in zip(out, items)])
    if not passed or dry:
        return summary
    wt = checked_out(root, into)
    if wt:
        if _git(wt, "status", "--porcelain", "--untracked-files=no").stdout.strip():
            raise DataError(f"{wt} has {into} checked out with uncommitted changes; not merged. "
                            f"Next: commit or remove those changes, then run it again")
        if _git(wt, "rev-parse", "HEAD").stdout.strip() != base:
            raise DataError(f"{into} moved during the merge step; not merged. Next: run the merge step again")
        _git(wt, "merge", "-q", "--ff-only", commit, check=True)
    else:
        _git(root, "update-ref", "-m", f"merge {sid}", f"refs/heads/{into}", commit, base, check=True)
    summary["merged"] = True
    return summary


# ------------------------------------------------------------------------- the plan as state
# plan/plan.json also holds the state of the run: the status, merge and log of each node, the
# exit items, the plan log and what waits for the user. scripts/plan writes it; check-plan judges
# each change against the committed plan/ (change_errors).

STATUSES = ("todo", "doing", "review", "done", "blocked")
ACTIVE = ("todo", "doing", "blocked")
NO_PLAN = ("no plan/plan.json: no requirement is in progress. "
           "Next: the user sets a requirement, then the coordinator runs scripts/plan new \"<title>\" on main")


def dump(doc):
    return json.dumps(doc, indent=2, ensure_ascii=False) + "\n"


def read_plan(root):
    """plan/plan.json of the working tree, checked with the whole plan/ tree."""
    files = worktree_files(root)
    if PLAN_FILE not in files:
        raise DataError(NO_PLAN)
    errs = tree_errors(files)
    if errs:
        raise DataError("\n".join(errs) + "\nNext: repair plan/ (scripts/plan lint lists the errors), "
                        "or `git checkout -- plan/` to go back to the committed plan")
    return json.loads(files[PLAN_FILE])


def find_node(plan, sid):
    n = next((n for n in plan["nodes"] if n["id"] == sid), None)
    if n is None:
        raise DataError(f"{sid} is not a node of {PLAN_FILE}. Next: `scripts/plan dag` lists the nodes; "
                        f"the coordinator adds one with `scripts/plan add`")
    return n


def statuses(root):
    """{ID: status} of plan/plan.json in the working tree ({} with no plan)."""
    p = Path(root, PLAN_FILE)
    if not p.exists():
        return {}
    try:
        return {n["id"]: n.get("status", "todo") for n in json.loads(p.read_text())["nodes"]}
    except (json.JSONDecodeError, KeyError, TypeError):
        return {}


def _bare(it):
    return {k: v for k, v in it.items() if k != "evidence"}


def _pointer_problem(root, ptr, tier):
    kind, sep, value = ptr.partition(":")
    value = value.strip().strip("`")
    if not sep or not value:
        return f"'{ptr}' is not a typed pointer (cmd: / test: / commit: / shot: / human:)"
    if kind == "cmd":
        exe = shlex.split(value)[0] if value else ""
        path = Path(root, exe)
        if not (path.is_file() and os.access(path, os.X_OK)):
            return f"cmd: {exe} is not an executable file of the repo"
    elif kind == "commit":
        if _git(root, "cat-file", "-e", f"{value}^{{commit}}").returncode != 0:
            return f"commit: {value} is not a commit of this repo"
    elif kind == "human":
        if tier != "human":
            return "human: is only for a [human] item"
        date = value.split(" ", 1)[0]
        try:
            datetime.date.fromisoformat(date)
        except ValueError:
            return f"human: '{date}' is not a YYYY-MM-DD date"
        if " " not in value.strip():
            return "human: needs a device or a note after the date"
    elif kind == "shot":
        if not Path(root, value).is_file():
            return f"shot: {value} does not exist"
    return None


def _item_changes(root, where, old, new, agent):
    errs = []
    for i, o in enumerate(old):
        if i >= len(new):
            errs.append(f"ITEM REMOVED: {where} item {i + 1} ({o['tier']}) {o['text'][:70]!r}. "
                        f"Next: put it back (`git checkout -- plan/`); only the user removes an item")
            continue
        n = new[i]
        if _bare(o) != _bare(n):
            errs.append(f"ITEM CHANGED: {where} item {i + 1}: tier, text, files and screens stay as they are.\n"
                        f"    old: [{o['tier']}] {o['text'][:100]}\n    new: [{n.get('tier')}] {str(n.get('text'))[:100]}\n"
                        f"  Next: put it back; to change it, tell the user the old text, the new text and why")
            continue
        ev_old, ev_new = o.get("evidence", []), n.get("evidence", [])
        lost = [p for p in ev_old if p not in ev_new]
        if lost:
            errs.append(f"EVIDENCE REMOVED: {where} item {i + 1}: {', '.join(lost)}. "
                        f"Next: put it back; evidence is only added")
        for p in ev_new:
            if p in ev_old:
                continue
            prob = _pointer_problem(root, p, n["tier"])
            if prob:
                errs.append(f"BAD EVIDENCE: {where} item {i + 1}: {prob}. Next: give a pointer that resolves")
            if agent and p.startswith("human:"):
                errs.append(f"HUMAN ITEM: {where} item {i + 1}: only the user records a [human] item. "
                            f"Next: leave it open; the coordinator lists it for the user (scripts/plan pending)")
    for j in range(len(old), len(new)):
        if new[j].get("evidence") and any(p.startswith("human:") for p in new[j]["evidence"]):
            errs.append(f"HUMAN ITEM: {where} item {j + 1} is added with a human: pointer. "
                        f"Next: add it open; only the user records it")
    return errs


def _log_changes(where, old, new):
    if new[:len(old)] != old:
        return [f"LOG CHANGED: {where}: the log is append-only. "
                f"Next: put the old entries back; add a new entry with scripts/plan log or slice-log"]
    return []


def change_errors(root, old_files, new_files, agent=False):
    """Errors of a change of plan/ from old_files to new_files ({path: text}): the new tree must be
    valid, nodes stay, items and exit items keep tier, text, files and screens and only gain
    evidence (pointers that resolve), logs are append-only. agent: no human: pointer."""
    errs = tree_errors(new_files)
    if errs:
        return [f"PLAN DATA: {e}" for e in errs] + \
            ["Next: repair plan/ (scripts/plan lint), or write it only with scripts/plan"]
    if PLAN_FILE not in old_files:
        return []
    try:
        old = {p: json.loads(t) for p, t in old_files.items()}
    except json.JSONDecodeError:
        return []
    new = {p: json.loads(t) for p, t in new_files.items()}
    op, np_ = old.get(PLAN_FILE), new.get(PLAN_FILE)
    if np_ is None:
        return ["PLAN REMOVED: plan/plan.json is gone. Next: when the exit passes, the user removes "
                "plan/ by hand; an agent does not"]
    nodes = {n["id"]: n for n in np_["nodes"]}
    for n in op.get("nodes", []):
        if n["id"] not in nodes:
            errs.append(f"NODE REMOVED: {n['id']}. Next: put it back; only the user removes a node")
            continue
        errs += _log_changes(f"{PLAN_FILE} {n['id']} log", n.get("log", []), nodes[n["id"]].get("log", []))
    errs += _log_changes(f"{PLAN_FILE} log", op.get("log", []), np_.get("log", []))
    errs += _item_changes(root, f"{PLAN_FILE} exit", op.get("exit", []), np_.get("exit", []), agent)
    for path, doc in old.items():
        if path == PLAN_FILE or path not in new:
            continue
        errs += _item_changes(root, path, doc.get("items", []), new[path].get("items", []), agent)
    return errs


def head_files(root, ref="HEAD"):
    """The plan/ files of a commit, or {} when the commit has none (or there is no commit)."""
    try:
        return committed_files(root, ref)
    except DataError:
        return {}


def ui_lines(root, sid):
    """For scripts/review: the demo of the node and its [ui] items, as tab-separated lines."""
    if not Path(root, PLAN_FILE).exists():
        return [f"ERR\t{NO_PLAN}"]
    try:
        node = find_node(json.loads(Path(root, PLAN_FILE).read_text()), sid)
        items = json.loads(Path(root, f"plan/{sid}.json").read_text())["items"]
    except (DataError, OSError, json.JSONDecodeError, KeyError) as e:
        return [f"ERR\t{e}"]
    out = [f"DEMO\t{node.get('demo') or ''}"]
    out += [f"UI\t{i}\t{' · '.join(it.get('evidence', []))}\t{it['text']}"
            for i, it in enumerate(items, 1) if it["tier"] == "ui"]
    return out


if __name__ == "__main__":
    import sys
    if len(sys.argv) == 3 and sys.argv[1] == "ui":
        print("\n".join(ui_lines(".", sys.argv[2])))
    else:
        sys.exit("usage: python3 scripts/lib/plandata.py ui <ID>")
