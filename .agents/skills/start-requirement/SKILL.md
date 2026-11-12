---
name: start-requirement
description: As the coordinator, start the next requirement from a GitHub milestone (for example M2) and write plan/ with scripts/plan, then stop for the user's review. Use when the user invokes /start-requirement.
disable-model-invocation: true
---

# Start a requirement

The argument is the milestone, for example `M2`: $ARGUMENTS. With no argument, use the open milestone with the lowest number. You are the coordinator.

1. Work on `main`. Stop and tell the user if `plan/plan.json` exists: one requirement at a time.
2. Read the requirement:
   - the milestone and its description: `gh api repos/laichang/dsh-mobile/milestones --jq '.[] | {number, title, description}'`;
   - its issues: `gh issue list --milestone <title> --state open --json number,title,labels,body`;
   - the open `upstream` issues: `gh issue list --label upstream --state open`. Ask the user whether the plan includes them;
   - what the issues cite: ARCHITECTURE.md, and STORY.md and design/screens.json for each change that the user sees.
3. Write the plan with `scripts/plan` only. Do not write `plan/` by hand. Do not commit it yet: until the user approves, you can write it again from the start.
   - `scripts/plan new "<milestone> · <short name>" --github-milestone "laichang/dsh-mobile#<milestone number>"`
   - `scripts/plan add tracer|spike|slice …` for each node, then `scripts/plan add exit "<check>"` for each real-device check.
   - Tracers first. Each tracer is one thin round trip that one session can finish: at most 3 items. A slice has at most 5. `scripts/plan` stops more. Use `[auto]` and `[ui]` items; use `[human]` only for a check that only a real device can do.
   - A design question that blocks a slice is a spike.
   - If a host installation or runtime requirement changes materially, include the target platforms, recommended approach and assumptions in the plan review. Record how the tracer will test each open assumption and what to do if it fails.
   - In `--why` of each slice, write the issues that it closes: "Closes #N". Each issue of the milestone is in one slice, or you tell the user why not.
   - Give a slice with `[ui]` items that have only `test:` pointers its demo: `--demo scripts/demo/<feature>.sh`.
4. Run `scripts/plan lint --github-milestone "laichang/dsh-mobile#<milestone number>"` with the number selected in step 2. Resolve any binding mismatch before presenting the plan. Run `scripts/plan dag`.
5. Report to the user, then stop:
   - the graph (`scripts/plan dag`), and one line for each tracer, spike and slice;
   - which issue goes where, and the questions that you have.

Do not assign or start a slice. The user reviews the plan and asks for changes. When the user approves it, commit it: `git add plan && git commit -m "plan: <milestone>"`. Then the user starts the run with `/run-plan`.
