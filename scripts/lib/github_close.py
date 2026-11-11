"""Synchronize completed plan nodes with their GitHub milestone."""
import json
import re
import subprocess

import dshm


def api(repo, path, *args):
    command = ["gh", "api", "--hostname", "github.com", f"repos/{repo}/{path}", *args]
    return json.loads(subprocess.check_output(command, text=True))


def pages(repo, path):
    return [item for page in api(repo, path, "--paginate", "--slurp") for item in page]


def origin_repo():
    origin = dshm.git("remote", "get-url", "origin")
    match = re.fullmatch(r"(?:https://github\.com/|ssh://git@github\.com/|git@github\.com:)"
                         r"([\w-]+/[\w.-]+)/?", origin)
    if not match:
        raise ValueError("cannot identify GitHub repository from origin")
    return match[1].removesuffix(".git")


def sync(plan):
    refs = {int(n) for node in plan["nodes"]
            for n in re.findall(r"\bCloses\s+#([1-9][0-9]*)\b", node.get("why", ""), re.I)}
    target = plan.get("github_milestone")
    if not target and not refs:
        return
    unfinished = [n["id"] for n in plan["nodes"] if n.get("status") != "done"]
    if unfinished:
        raise ValueError(f"unfinished plan nodes: {', '.join(unfinished)}")

    repo = origin_repo()
    if target:
        expected, number = target.split("#")
        if expected.lower() != repo.lower():
            raise ValueError(f"plan repository {expected} does not match origin {repo}")
        milestone = api(repo, f"milestones/{int(number)}")["number"]
    else:
        label = plan["title"].split(" · ")[0]
        matches = [m["number"] for m in pages(repo, "milestones?state=all&per_page=100")
                   if m["title"].split(" · ")[0] == label]
        if len(matches) != 1:
            raise ValueError(f"cannot identify one milestone for legacy plan {plan['title']!r} in {repo}")
        milestone = matches[0]

    def issues():
        rows = pages(repo, f"issues?milestone={milestone}&state=all&per_page=100")
        return {row["number"]: row["state"] for row in rows if "pull_request" not in row}

    states = issues()
    outside = refs - states.keys()
    if outside:
        raise ValueError(f"referenced issues outside {repo} milestone {milestone}: {sorted(outside)}")
    opened = {n for n, state in states.items() if state == "open"}
    if opened - refs:
        raise ValueError(f"open issues without a Closes reference: {sorted(opened - refs)}")
    for n in sorted(opened):
        api(repo, f"issues/{n}", "--method", "PATCH", "-f", "state=closed", "-f", "state_reason=completed")
    remaining = [n for n, state in issues().items() if state == "open"]
    if remaining:
        raise ValueError(f"milestone {milestone} still has open issues: {sorted(remaining)}")
    print(f"plan close: verified zero open issues in {repo} milestone {milestone}")
