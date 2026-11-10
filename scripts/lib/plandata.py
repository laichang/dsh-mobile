"""The plan as data: plan/plan.json (the graph), plan/<ID>.json (the items), and verifier results.

  plan/plan.json   {"title", "nodes": [{"id", "kind", "title", "needs", "branch"}]}
  plan/<ID>.json   {"id", "items": [{"tier", "text", "files", "screens", "passed": false}]}

The schema is scripts/lib/plan.schema.json. This module checks it (a small validator for the part
of JSON Schema that the file uses: no dependency) and the rules a schema cannot say: unique IDs,
the kind of each ID, known needs, no cycle, one plan/<ID>.json for each node.

`passed` in a plan/<ID>.json is always false. The value that counts is derived: the verifier
results for the head commit of the slice branch. A verifier stores them with `scripts/plan
record`, as a git note on that commit (ref refs/notes/dshm-verify, shared by all worktrees). The
results are not in a commit of the branch, so no edit on the branch can make them, and a new
commit has no results until a verifier runs again: old results are stale.

Used by scripts/plan (dag, passed, record, lint) and by scripts/check-plan (staged plan/ files).
"""

import json
import re
import subprocess
from pathlib import Path

PLAN_DIR = "plan"
PLAN_FILE = "plan/plan.json"
NOTES_REF = "refs/notes/dshm-verify"
SCHEMA_PATH = Path(__file__).resolve().with_name("plan.schema.json")
PREFIX = {"tracer": "T", "spike": "X", "slice": "S"}
SLICE_FILE_RE = re.compile(r"^plan/(?P<id>(T|X|S)\d+)\.json$")
STALE_DEPTH = 50                # how far back `passed` looks for stale results


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
        raise DataError("\n".join(errs))
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
    ids = {n["id"] for n in plan.get("nodes", []) if isinstance(n, dict) and "id" in n} if not perr else set()
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
        raise DataError(f"{PLAN_FILE} does not exist")
    errs = tree_errors(files)
    if errs:
        raise DataError("\n".join(errs))
    plan = json.loads(files[PLAN_FILE])
    items = {n["id"]: json.loads(files[f"plan/{n['id']}.json"])["items"] for n in plan["nodes"]}
    return plan, items


def load_plan(root):
    p = Path(root, PLAN_FILE)
    if not p.exists():
        raise DataError(f"{PLAN_FILE} does not exist")
    try:
        return json.loads(p.read_text())
    except json.JSONDecodeError as e:
        raise DataError(f"{PLAN_FILE}: not JSON ({e})")


# ---------------------------------------------------------------------------------- results

def _git(root, *args, check=False, input=None):
    r = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, input=input)
    if check and r.returncode != 0:
        raise DataError(f"git {' '.join(args)} failed: {r.stderr.strip()}")
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
    res = note(root, commit).get(sid)
    if not isinstance(res, dict) or check_against(res, "results", "note") or res["commit"] != commit:
        return None
    return res


def record(root, sid, results):
    """Store verifier results for the head commit of the branch of sid. Returns the commit."""
    errs = check_against(results, "results", "results")
    if errs:
        raise DataError("\n".join(errs))
    if results["slice"] != sid:
        raise DataError(f"the results are for {results['slice']}, not {sid}")
    plan, items = load(root)
    node = next((n for n in plan["nodes"] if n["id"] == sid), None)
    if node is None:
        raise DataError(f"{sid} is not a node of {PLAN_FILE}")
    head = branch_head(root, node["branch"])
    if head is None:
        raise DataError(f"{sid} has no branch with a commit ({node['branch']})")
    if results["commit"] != head:
        raise DataError(f"the results are for {results['commit'][:12]}, but the head of {node['branch']} "
                        f"is {head[:12]}: results for an older commit are stale")
    n = len(items[sid])
    seen = set()
    for r in results["items"]:
        if r["item"] >= n:
            raise DataError(f"{sid} has {n} items; there is no item {r['item']}")
        if r["item"] in seen:
            raise DataError(f"item {r['item']} has two results")
        seen.add(r["item"])
    data = note(root, head)
    data[sid] = results
    _git(root, "notes", f"--ref={NOTES_REF}", "add", "-f", "-F", "-", head, check=True,
         input=json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    return head


def derive(root, sid):
    """passed of each item of sid, from the verifier results for the head of its branch."""
    plan, items = load(root)
    node = next((n for n in plan["nodes"] if n["id"] == sid), None)
    if node is None:
        raise DataError(f"{sid} is not a node of {PLAN_FILE}")
    head = branch_head(root, node["branch"])
    res = results_for(root, sid, head) if head else None
    by_item = {r["item"]: r for r in res["items"]} if res else {}
    out_items = []
    for i, it in enumerate(items[sid]):
        r = by_item.get(i, {})
        out_items.append({"item": i, "tier": it["tier"], "text": it["text"],
                          "passed": bool(r.get("passed")), "evidence": r.get("evidence", "")})
    stale = None
    if head and res is None:
        log = _git(root, "rev-list", f"--max-count={STALE_DEPTH}", head).stdout.split()
        stale = next((c for c in log[1:] if results_for(root, sid, c)), None)
    checked = [i for i in out_items if i["tier"] != "human"]
    return {
        "id": sid, "branch": node["branch"], "head": head,
        "verifier": res["verifier"] if res else None,
        "stale": stale,
        "passed": bool(res) and bool(checked) and all(i["passed"] for i in checked),
        "items": out_items,
    }
