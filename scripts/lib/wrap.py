"""Output wrappers for build and test tools (scripts/xc, scripts/swift-test, scripts/pnpm-test).

Stdlib only. Runs one tool, writes its full output to a log file, and prints a short JSON summary:

    {
      "tool": "swift test",
      "ok": false,
      "exit": 1,
      "tests": {"passed": 120, "failed": 1, "skipped": 0},
      "errors": [
        "ios/DSHKit/Tests/DSHKitTests/FooTests.swift:12: Expectation failed: (a → 1) == 2"
      ],
      "log": "/tmp/dshm-logs/swift-test-20261110-101500-4242.log"
    }

Each error is one line, "file:line: message", with the file relative to the repository when it is
in the repository. "errors" holds the first DSHM_WRAP_ERRORS (10) errors; the log has all of them.
A passing run prints 10 lines or fewer. The exit code is the exit code of the tool.

    wrap.py run <kind> [--log FILE] [tool args…]   kind: xc | swift-test | pnpm-test
    wrap.py parse <kind> <log> [exit code]          summary of an existing log (tests of this file)

The log goes to --log FILE, or else to $DSHM_LOG_DIR (/tmp/dshm-logs)/<kind>-<time>-<pid>.log.
scripts/review finds the logs through the "log" lines in its own output.
"""

import datetime
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MAX_ERRORS = int(os.environ.get("DSHM_WRAP_ERRORS", "10"))
MAX_MSG = 200

XC_ACTIONS = ("build", "test", "build-for-testing", "test-without-building", "clean", "analyze")


def rel(path):
    """A path relative to the repository when it is in the repository."""
    p = path.strip()
    if p.startswith("file://"):
        p = p[len("file://"):]
    try:
        r = Path(p).resolve().relative_to(ROOT)
        return str(r)
    except (ValueError, OSError):
        return p


def short(msg):
    msg = " ".join(msg.split())
    return msg if len(msg) <= MAX_MSG else msg[:MAX_MSG - 1] + "…"


# The package that swift test runs; Swift Testing prints only the base name of a source file.
SWIFT_DIR = ROOT / "ios/DSHKit"


def find_source(name, under):
    """The path of a bare file name under the package, relative to the repository if possible."""
    if "/" in name:
        return rel(name)
    under = Path(under)
    hits = [h for h in sorted(under.rglob(name)) if ".build" not in h.parts] if under.is_dir() else []
    return rel(str(hits[0])) if len(hits) == 1 else name


class Errors:
    def __init__(self):
        self.items, self.seen = [], set()

    def add(self, file, line, msg):
        key = (file, str(line), short(msg))
        if key in self.seen:
            return
        self.seen.add(key)
        self.items.append(f"{file}:{line}: {short(msg)}")


# file:line[:col]: error: message   (clang, swiftc, XCTest assertion failures, ld)
COMPILER_ERR = re.compile(r"^(?P<file>/[^:\n]+?):(?P<line>\d+)(?::\d+)?: (?:fatal )?error: (?P<msg>.*)$")


def parse_xc(text):
    errors = Errors()
    passed = failed = skipped = 0
    for line in text.splitlines():
        m = COMPILER_ERR.match(line.strip())
        if m:
            msg = m.group("msg")
            # XCTest: "-[dsh_mobileUITests.Suite testName] : XCTAssertTrue failed - …"
            msg = re.sub(r"^-\[[\w.]+ (\w+)\] : ", r"\1: ", msg)
            errors.add(rel(m.group("file")), m.group("line"), msg)
            continue
        m = re.match(r"^Test Case '-\[\S+ \S+\]' (passed|failed|skipped)", line)
        if m:
            if m.group(1) == "passed":
                passed += 1
            elif m.group(1) == "failed":
                failed += 1
            else:
                skipped += 1
    other = []
    if not errors.items:
        # No file:line error: keep the plain "error:" lines (a bad destination, a signing problem).
        for line in text.splitlines():
            s = line.strip()
            if re.search(r"(^|\s)error: ", s) or s.startswith("xcodebuild: error"):
                other.append(short(s))
    tests = {"passed": passed, "failed": failed, "skipped": skipped} if passed + failed + skipped else None
    return tests, errors.items, other


def parse_swift(text):
    errors = Errors()
    for line in text.splitlines():
        s = line.strip()
        m = COMPILER_ERR.match(s)
        if m:
            errors.add(rel(m.group("file")), m.group("line"), m.group("msg"))
            continue
        # Swift Testing:  ✘ Test name() recorded an issue at FooTests.swift:12:5: Expectation failed: …
        m = re.match(r"^✘ Test (?P<name>.+?) recorded an issue at (?P<file>[^:]+):(?P<line>\d+)(?::\d+)?: (?P<msg>.*)$", s)
        if m:
            name = m.group("name").strip('"')
            errors.add(find_source(m.group("file"), SWIFT_DIR), m.group("line"), f"{name}: {m.group('msg')}")
    # Counts. Swift Testing: "✔ Test run with 120 tests in 15 suites passed after …" or
    # "✘ Test run with 120 tests in 15 suites failed after … with 2 issues."
    total = None
    m = None
    for m in re.finditer(r"Test run with (\d+) tests?", text):
        pass
    if m:
        total = int(m.group(1))
    failed = len({n for n in re.findall(r"^\s*✘ Test (.+?) failed after", text, re.M) if not n.startswith("run with")})
    skipped = len(re.findall(r"^\s*\S+ Test .+? skipped", text, re.M))
    # XCTest in swift test: "Executed 12 tests, with 1 failure (0 unexpected) …"
    xc_total = xc_failed = 0
    for em in re.finditer(r"Executed (\d+) tests?, with (\d+) failures?", text):
        xc_total, xc_failed = int(em.group(1)), int(em.group(2))
    tests = None
    if total is not None or xc_total:
        t = (total or 0) + xc_total
        f = failed + xc_failed
        tests = {"passed": max(t - f - skipped, 0), "failed": f, "skipped": skipped}
    other = []
    if not errors.items:
        for line in text.splitlines():
            s = line.strip()
            if re.match(r"^(error|fatal):", s) or " error: " in s:
                other.append(short(s))
    return tests, errors.items, other


def parse_pnpm(text):
    errors = Errors()
    for line in text.splitlines():
        s = line.strip()
        # tsc: src/foo.ts(12,5): error TS2322: …
        m = re.match(r"^(?P<file>[^\s(]+\.[cm]?tsx?)\((?P<line>\d+),\d+\): error (?P<msg>.*)$", s)
        if m:
            errors.add(map_js(m.group("file")), m.group("line"), m.group("msg"))
    # node:test spec reporter, after "✖ failing tests:":
    #   test at lib/test/foo.test.js:12:3
    #   ✖ name (1.2ms)
    #     AssertionError [ERR_ASSERTION]: …
    lines = text.splitlines()
    if "✖ failing tests:" in text:
        start = next(n for n, l in enumerate(lines) if l.strip() == "✖ failing tests:")
        heads = [n for n in range(start + 1, len(lines)) if re.match(r"^\s*test at .+:\d+:\d+\s*$", lines[n])]
        for h, n in enumerate(heads):
            end = heads[h + 1] if h + 1 < len(heads) else len(lines)
            m = re.match(r"^\s*test at (?P<file>.+?):(?P<line>\d+):\d+\s*$", lines[n])
            file, line = m.group("file"), m.group("line")
            block = lines[n + 1:end]
            name = re.sub(r" \([\d.]+m?s\)$", "", re.sub(r"^\s*✖ ", "", block[0]).strip()) if block else ""
            msg = [t.strip() for t in block[1:] if t.strip() and not t.strip().startswith("at ")][:2]
            # The assertion line: the first stack frame in the same test file.
            base = os.path.basename(file)
            for t in block:
                fm = re.search(r"\((?:file://)?(?P<f>[^()]+?):(?P<l>\d+):\d+\)\s*$", t) or \
                    re.search(r"at (?:file://)?(?P<f>/\S+?):(?P<l>\d+):\d+\s*$", t)
                if fm and os.path.basename(fm.group("f")) == base:
                    line = fm.group("l")
                    break
            errors.add(map_js(file), line, f"{name}: {' '.join(msg)}" if msg else name)
    counts = {}
    for key in ("tests", "pass", "fail", "skipped", "todo", "cancelled"):
        m = None
        for m in re.finditer(rf"^[ℹ#] {key} (\d+)\s*$", text, re.M):
            pass
        if m:
            counts[key] = int(m.group(1))
    tests = None
    if counts:
        tests = {"passed": counts.get("pass", 0), "failed": counts.get("fail", 0) + counts.get("cancelled", 0),
                 "skipped": counts.get("skipped", 0) + counts.get("todo", 0)}
    other = []
    if not errors.items:
        for s in (l.strip() for l in lines):
            if re.search(r"(^|\s)(ERR_PNPM_\w+|error TS\d+|Error:)", s):
                other.append(short(s))
    return tests, errors.items, other


# The directory where pnpm test runs; node:test and tsc print paths relative to it.
PNPM_DIR = ROOT / "bridge"


def map_js(path):
    """A node:test path, relative to the repository; lib/x.js -> x.ts when the source exists."""
    p = path[len("file://"):] if path.startswith("file://") else path
    if not p.startswith("/"):
        p = str(PNPM_DIR / p)
    m = re.match(r"^(?P<dir>.*)/lib/(?P<rest>.+)\.js$", p)
    if m and Path(f"{m.group('dir')}/{m.group('rest')}.ts").exists():
        p = f"{m.group('dir')}/{m.group('rest')}.ts"
    return rel(p)


PARSERS = {"xc": parse_xc, "swift-test": parse_swift, "pnpm-test": parse_pnpm, "node-test": parse_pnpm}
TOOL_NAMES = {"xc": "xcodebuild", "swift-test": "swift test", "pnpm-test": "pnpm test", "node-test": "node --test"}


def summary(kind, action, text, code, log):
    tests, errs, other = PARSERS[kind](text)
    out = {"tool": TOOL_NAMES[kind] + (f" {action}" if action else ""), "ok": code == 0, "exit": code}
    if tests is not None:
        out["tests"] = tests
    all_errs = errs or other
    if code != 0 and not all_errs:
        tail = [short(l) for l in text.splitlines() if l.strip()][-3:]
        all_errs = tail
    if all_errs:
        out["errors"] = all_errs[:MAX_ERRORS]
        if len(all_errs) > MAX_ERRORS:
            out["more_errors"] = len(all_errs) - MAX_ERRORS
    out["log"] = str(log)
    return out


def dump(obj):
    """JSON with one key per line and one error per line, so an error is one file:line line."""
    lines = ["{"]
    items = list(obj.items())
    for n, (k, v) in enumerate(items):
        comma = "," if n < len(items) - 1 else ""
        if isinstance(v, list):
            lines.append(f'  "{k}": [')
            for i, e in enumerate(v):
                lines.append("    " + json.dumps(e, ensure_ascii=False) + ("," if i < len(v) - 1 else ""))
            lines.append("  ]" + comma)
        else:
            lines.append(f'  "{k}": ' + json.dumps(v, ensure_ascii=False) + comma)
    lines.append("}")
    return "\n".join(lines)


def default_log(kind, action):
    d = Path(os.environ.get("DSHM_LOG_DIR", "/tmp/dshm-logs"))
    d.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    name = kind + (f"-{action}" if action else "")
    return d / f"{name}-{stamp}-{os.getpid()}.log"


def has(args, *flags):
    return any(a in flags for a in args)


def xc_command(args):
    """xcodebuild <action> [args]. A bare call gets the project, the scheme and a destination."""
    if not args or args[0] not in XC_ACTIONS:
        raise SystemExit(f"usage: scripts/xc {{{'|'.join(XC_ACTIONS)}}} [--log FILE] [xcodebuild args…]")
    action, rest = args[0], args[1:]
    cmd = ["xcodebuild", action]
    if action in ("build-for-testing", "test") and not any(arg.startswith("DSHM_DEBUG_APP_PLIST=") for arg in rest):
        cmd.append("DSHM_DEBUG_APP_PLIST=Config/Debug-Info.plist")
    if not has(rest, "-project", "-workspace"):
        cmd += ["-project", str(ROOT / "ios/dsh-mobile.xcodeproj"), "-scheme", "dsh-mobile",
                "-onlyUsePackageVersionsFromResolvedFile", "-skipPackageUpdates"]
    if not has(rest, "-destination"):
        sim = os.environ.get("DSHM_SIM", "")
        if action == "build" and not sim:
            dest = "generic/platform=iOS Simulator"
        elif re.fullmatch(r"[0-9A-F-]{36}", sim):
            dest = f"platform=iOS Simulator,id={sim}"
        else:
            dest = f"platform=iOS Simulator,name={sim or 'iPhone 17 Pro'}"
        cmd += ["-destination", dest]
    if not has(rest, "-derivedDataPath") and os.environ.get("DSHM_DD"):
        cmd += ["-derivedDataPath", os.environ["DSHM_DD"]]
    return action, cmd + rest


def run(kind, argv):
    global SWIFT_DIR, PNPM_DIR
    log = None
    args = []
    i = 0
    while i < len(argv):
        if argv[i] == "--log" and i + 1 < len(argv):
            log = Path(argv[i + 1])
            i += 2
            continue
        args.append(argv[i])
        i += 1
    if kind == "xc":
        action, cmd = xc_command(args)
        cwd = None
    elif kind == "swift-test":
        action = None
        cmd = ["swift", "test"] + args
        if has(args, "--package-path"):
            SWIFT_DIR = Path(args[args.index("--package-path") + 1]).resolve()
        else:
            cmd += ["--package-path", str(SWIFT_DIR)]
        cwd = None
    else:
        action = None
        # pnpm test in bridge/ (or --dir DIR)
        d = ROOT / "bridge"
        if "--dir" in args:
            k = args.index("--dir")
            d = Path(args[k + 1])
            args = args[:k] + args[k + 2:]
        if args[:1] == ["--node-test"]:
            kind, args = "node-test", args[1:]
        cmd = (["node", "--test"] if kind == "node-test" else ["corepack", "pnpm", "test"]) + args
        cwd = d
        PNPM_DIR = d.resolve()
    log = log or default_log(kind, action)
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "w") as f:
        f.write("$ " + " ".join(cmd) + "\n")
        f.flush()
        try:
            code = subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT,
                                  stdin=subprocess.DEVNULL).returncode
        except FileNotFoundError as e:
            f.write(f"error: {e}\n")
            code = 127
        except KeyboardInterrupt:
            code = 130
    if code < 0:
        code = 128 - code
    text = log.read_text(errors="replace")
    print(dump(summary(kind, action, text, code, log)), flush=True)
    return code


def main():
    if len(sys.argv) < 3 or sys.argv[1] not in ("run", "parse") or sys.argv[2] not in PARSERS:
        print(__doc__, file=sys.stderr)
        return 2
    kind = sys.argv[2]
    if sys.argv[1] == "parse":
        log = Path(sys.argv[3])
        code = int(sys.argv[4]) if len(sys.argv) > 4 else 0
        print(dump(summary(kind, None, log.read_text(errors="replace"), code, log)))
        return 0
    return run(kind, sys.argv[3:])


if __name__ == "__main__":
    sys.exit(main())
