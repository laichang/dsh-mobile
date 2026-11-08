"""The PLAN.md format: write a new plan, add sections, draw the map, lint (scripts/plan).

A plan exists only while a requirement is in progress (WORKFLOW.md §3.1). `scripts/plan new`
writes it from plan-template.md; `scripts/plan add` adds tracer bullets, spikes, slices and exit
items in the format below; every `scripts/plan` write redraws §2 Map and runs lint() first.
"""

import re
from pathlib import Path

import dshm

TEMPLATE = Path(__file__).resolve().parent / "plan-template.md"

SECTIONS = ["How to use this file", "0. Status", "1. Approach", "2. Map", "3. Tracer bullets",
            "4. Spikes", "5. Slices", "6. Exit", "7. Not in this plan", "8. Plan log",
            "9. Pending user confirmation"]

# kind: (ID prefix, section, first number, title prefix)
KINDS = {
    "tracer": ("T", "## 3. Tracer bullets", 0, "Tracer bullet: "),
    "spike": ("X", "## 4. Spikes", 1, "Spike: "),
    "slice": ("S", "## 5. Slices", 1, ""),
}
SECTION_OF = {prefix: heading for prefix, heading, _, _ in KINDS.values()}
MAX_TRACER_ITEMS = 3   # a tracer is one thin round trip that one session can finish
MAX_SLICE_ITEMS = 5    # a slice is also built by one session
FIELDS = ["**Status** ", "**Why**", "**Cuts**", "**Demo**", "**Done when**", "**Not**", "**Log**"]
HEAD_RE = re.compile(r"^### (?P<id>[TXS]\d+) · (?P<title>.+?)\s*$")
NEEDS_RE = re.compile(r"\*\*Needs\*\* (?P<needs>.*?) · \*\*Branch\*\*")
STATUS_LINE_RE = re.compile(r"^\*\*Status\*\* (?P<status>\S+) · \*\*Needs\*\* .+ · \*\*Branch\*\* .+$")
ID_RE = re.compile(r"\b[TXS]\d+\b")
MAP_NOTE = "`scripts/plan` writes this map from the **Needs** of each tracer, spike and slice. Do not edit it."

NO_PLAN = ("no PLAN.md: no requirement is in progress. When the user has set a requirement, the "
           "coordinator starts the plan on main with `scripts/plan new \"<title>\"` (WORKFLOW.md "
           "§3.1). Ideas and bugs without a plan are GitHub issues.")


def new_plan(title):
    title = " ".join(title.split()).rstrip(".")
    if not title:
        raise dshm.PlanError("the plan needs a title, e.g. \"M2 · Push and replies\"")
    return (TEMPLATE.read_text().replace("{{TITLE}}", title).replace("{{DATE}}", dshm.today()))


def plan_title(lines):
    """The requirement name from '# PLAN · <title>', up to the first ' · '."""
    for line in lines:
        if line.startswith("# PLAN · "):
            return line[len("# PLAN · "):].split(" · ")[0].strip()
    return "plan"


# ------------------------------------------------------------------------------- reading

def sections(lines):
    """[(start, end, id, title)] for each '### <ID> · …' section."""
    out = []
    heads = [(i, HEAD_RE.match(l)) for i, l in enumerate(lines)]
    heads = [(i, m) for i, m in heads if m]
    for i, m in heads:
        e = next((j for j in range(i + 1, len(lines))
                  if lines[j].startswith("### ") or lines[j].startswith("## ")), len(lines))
        out.append((i, e, m.group("id"), m.group("title")))
    return out


def needs_of(lines, s, e):
    for i in range(s, e):
        m = NEEDS_RE.search(lines[i])
        if m:
            return ID_RE.findall(m.group("needs"))
    return []


def ids_in_plan(lines):
    ids = {sid for _, _, sid, _ in sections(lines)}
    ids |= {r["id"] for _, r in dshm.status_table(lines)}
    return ids


def next_id(lines, kind):
    prefix, _, first, _ = KINDS[kind]
    nums = [int(sid[1:]) for sid in ids_in_plan(lines) if sid.startswith(prefix)]
    return f"{prefix}{max(nums) + 1 if nums else first}"


# ------------------------------------------------------------------------------- writing

def field(name, value):
    """'**Name**: value' for one line; '**Name**' then the lines for a multi-line value."""
    value = (value or "").strip("\n")
    if not value.strip():
        value = "—"
    if "\n" in value:
        return [f"**{name}**", *[l.rstrip() for l in value.split("\n")]]
    return [f"**{name}**: {value.strip()}"]


def done_item(text):
    text = " ".join(text.split())
    m = re.match(r"^\[(auto|ui|human)\]\s+(.+)$", text)
    if not m:
        raise dshm.PlanError(f"a Done when item starts with [auto], [ui] or [human]: {text!r}")
    return f"- [ ] [{m.group(1)}] {m.group(2).rstrip()} — Evidence:"


def section_lines(sid, title, needs, why, cuts, demo, done, not_):
    if not done:
        raise dshm.PlanError(f"{sid} needs at least one Done when item (--done \"[auto] …\")")
    return [
        f"### {sid} · {title}",
        "",
        f"**Status** todo · **Needs** {', '.join(needs) or '—'} · **Branch** —",
        "",
        *field("Why", why), "",
        *field("Cuts", cuts), "",
        *field("Demo", demo), "",
        "**Done when**",
        *[done_item(d) for d in done], "",
        *field("Not", not_), "",
        "**Log**: —",
    ]


def insert_section(lines, heading, section):
    """Put section at the end of the '## …' section heading, one blank line before the next."""
    _, e = dshm.section_bounds(lines, heading)
    while e > 0 and lines[e - 1].strip() == "":
        e -= 1
    lines[e:e] = ["", *section]


def insert_row(lines, sid, nxt):
    s, e = dshm.section_bounds(lines, "## 0. Status")
    rows = dshm.status_table(lines)
    at = rows[-1][0] if rows else next(
        (i for i in range(s, e) if lines[i].startswith("|---")), None)
    if at is None:
        raise dshm.PlanError("§0 has no table")
    lines.insert(at + 1, dshm.format_row([sid, "todo", "—", dshm.today(), nxt.replace("|", "/")]))


def add(lines, kind, name, needs=None, why="", cuts="", demo="", done=(), not_="",
        nxt="Assign it and start a session"):
    """Add a tracer, spike or slice: the next ID, a §0 row, a section. Returns the ID."""
    sid = next_id(lines, kind)
    prefix, heading, _, title_prefix = KINDS[kind]
    name = " ".join(name.split()).rstrip(".")
    if not name:
        raise dshm.PlanError("give the section a name")
    if title_prefix and not name.startswith(title_prefix):
        name = title_prefix + name
    if needs is None:   # a slice needs the first tracer, unless it says otherwise
        tracers = sorted((x for x in ids_in_plan(lines) if x.startswith("T")), key=lambda x: int(x[1:]))
        needs = tracers[:1] if kind == "slice" else []
    known = ids_in_plan(lines)
    missing = [n for n in needs if n not in known]
    if missing:
        raise dshm.PlanError(f"Needs names IDs that this plan does not have: {', '.join(missing)}")
    if len(done) > item_limit(sid):
        raise dshm.PlanError(tracer_limit(sid, len(done)))
    insert_section(lines, heading, section_lines(sid, name, needs, why, cuts, demo, list(done), not_))
    insert_row(lines, sid, nxt)
    return sid


def item_limit(sid):
    """The most Done when items a section may have; spikes have no limit."""
    return {"T": MAX_TRACER_ITEMS, "S": MAX_SLICE_ITEMS}.get(sid[0], 10 ** 6)


def tracer_limit(sid, n):
    kind = "tracer" if sid.startswith("T") else "slice"
    split = "more tracers or move the rest to slices" if kind == "tracer" else "more slices"
    return (f"{sid}: a {kind} has at most {item_limit(sid)} Done when items ({n} given), so that one "
            f"session can finish it. Split it into {split}")


def add_exit(lines, text):
    item = done_item(text if text.lstrip().startswith("[") else f"[human] {text}")
    if "[human]" not in item:
        raise dshm.PlanError("exit items are [human] only (§6)")
    s, e = dshm.section_bounds(lines, "## 6. Exit")
    at = max((i for i in range(s, e) if lines[i].startswith("- [")), default=None)
    if at is None:
        at = e
        while lines[at - 1].strip() == "":
            at -= 1
        lines[at:at] = ["", item]
    else:
        lines.insert(at + 1, item)


# ------------------------------------------------------------------------------- map

def label(text):
    return '"' + text.replace('"', "#quot;") + '"'


def map_lines(lines):
    out = ["flowchart LR"]
    secs = sections(lines)
    for s, e, sid, title in secs:
        shape = "([{}])" if sid.startswith("T") else "[{}]"
        out.append("    " + sid + shape.format(label(f"{sid} · {title}")))
    edges = []
    for s, e, sid, _ in secs:
        for n in needs_of(lines, s, e):
            edges.append(f"    {n} {'-.->' if n.startswith('X') else '-->'} {sid}")
    if edges:
        out += ["", *edges]
    return out


def redraw_map(lines):
    """Replace the mermaid block in §2 with the map drawn from the Needs fields."""
    try:
        s, e = dshm.section_bounds(lines, "## 2. Map")
    except dshm.PlanError:
        return
    start = next((i for i in range(s, e) if lines[i].strip() == "```mermaid"), None)
    if start is None:
        return
    end = next((i for i in range(start + 1, e) if lines[i].strip() == "```"), None)
    if end is None:
        return
    lines[start + 1:end] = map_lines(lines)


# ------------------------------------------------------------------------------- lint

def lint(lines):
    """Format errors of the plan (a list of strings; empty = OK)."""
    errs = []
    heads = [l[3:].strip() for l in lines if l.startswith("## ")]
    if heads != SECTIONS:
        errs.append("sections must be, in order: " + " | ".join(SECTIONS) +
                    f" (found: {' | '.join(heads)})")
        return errs
    if not lines or not lines[0].startswith("# PLAN · "):
        errs.append("the first line is '# PLAN · <title>'")

    # §2: the map is drawn, not edited
    s, e = dshm.section_bounds(lines, "## 2. Map")
    block = lines[s:e]
    if "```mermaid" in [l.strip() for l in block]:
        i = [l.strip() for l in block].index("```mermaid")
        j = next((k for k in range(i + 1, len(block)) if block[k].strip() == "```"), None)
        if j is None or block[i + 1:j] != map_lines(lines):
            errs.append("§2 Map does not match the Needs fields; `scripts/plan` redraws it")
    else:
        errs.append("§2 Map has no ```mermaid block")

    secs = sections(lines)
    seen = {}
    for s, e, sid, title in secs:
        if sid in seen:
            errs.append(f"{sid}: two sections")
        seen[sid] = (s, e)
        where = next(lines[k] for k in range(s, -1, -1) if lines[k].startswith("## "))
        if where != SECTION_OF[sid[0]]:
            errs.append(f"{sid}: belongs in {SECTION_OF[sid[0]][3:]}, not in {where[3:]}")
        body = lines[s + 1:e]
        idx = []
        for f in FIELDS:
            hits = [k for k, l in enumerate(body) if l.startswith(f)]
            if len(hits) != 1:
                errs.append(f"{sid}: {'no' if not hits else 'more than one'} {f.strip()} field")
                idx.append(None)
            else:
                idx.append(hits[0])
        if None not in idx:
            if idx != sorted(idx):
                errs.append(f"{sid}: fields must be in this order: "
                            + ", ".join(f.strip() for f in FIELDS))
            elif not STATUS_LINE_RE.match(body[idx[0]]):
                errs.append(f"{sid}: the first field line is "
                            "'**Status** <status> · **Needs** <IDs or —> · **Branch** <branch or —>'")
            else:
                st = STATUS_LINE_RE.match(body[idx[0]]).group("status")
                if st not in dshm.STATUSES:
                    errs.append(f"{sid}: status {st!r} is not one of {', '.join(dshm.STATUSES)}")
                done = [l for l in body[idx[4] + 1:idx[5]] if dshm.ITEM_RE.match(l)]
                if not done:
                    errs.append(f"{sid}: Done when has no item")
                if len(done) > item_limit(sid):
                    errs.append(tracer_limit(sid, len(done)))
    known = set(seen)
    for s, e, sid, _ in secs:
        for n in needs_of(lines, s, e):
            if n not in known:
                errs.append(f"{sid}: Needs {n}, which has no section")
            if n == sid:
                errs.append(f"{sid}: needs itself")

    rows = dshm.status_table(lines)
    row_ids = [r["id"] for _, r in rows]
    for sid in sorted(set(x for x in row_ids if row_ids.count(x) > 1)):
        errs.append(f"§0: two rows for {sid}")
    for sid in sorted(known - set(row_ids)):
        errs.append(f"§0: no row for {sid}")
    for sid in sorted(set(row_ids) - known):
        errs.append(f"§0: row {sid} has no section")
    for _, r in rows:
        if r["status"] not in dshm.STATUSES:
            errs.append(f"§0 {r['id']}: status {r['status']!r} is not one of {', '.join(dshm.STATUSES)}")

    s, e = dshm.section_bounds(lines, "## 6. Exit")
    for l in lines[s:e]:
        m = dshm.ITEM_RE.match(l)
        if m and m.group("tier") != "human":
            errs.append(f"§6: exit items are [human] only: {l[:80]}")

    s, e = dshm.section_bounds(lines, "## 7. Not in this plan")
    if any(re.match(r"^\s*(- |\* |\d+\. |\|)", l) for l in lines[s + 1:e]):
        errs.append("§7: do not list ideas or follow-ups in the plan; open GitHub issues for them")
    return errs
