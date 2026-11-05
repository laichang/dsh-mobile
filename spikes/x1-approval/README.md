# X1 · Spike: approval answerer: conclusion

Working note for PLAN.md X1 (answers ARCHITECTURE §8.1, feeds S4). Archive it to `.archive/YYYYMMDD/x1-approval.md` once S4 has acted on it. Measured on 2026-11-05 against DSH `0.2.2-rc.1` (`dsh web`, mock LLM, `DSH_HOME=~/.dshm/home-x1x4`).

## Answer

**Yes, with one exception and one caveat.**

- **A plugin answerer owns approvals for every root agent.** One unscoped `ctx.on('approval/request', fn, { prepend: true })` receives the request of every session in the process, whichever client created it. It can hold the request as long as it likes: DSH has no timeout. The request's `signal` aborts when the turn is cancelled, and the plugin settles it `cancelled`. Both real approval paths reach it: a `tools/pre-execute` `ask` decision, and the sandboxed `bash` tool's `danger-full-access` escalation.
- **Exception: subagents never ask.** DSH pins every delegated child to approval policy `never` (`dsh-subagent`: a child's approval-requiring operations "are rejected automatically"). The approval service rejects the child's request *before* dispatching any answerer, so no plugin and no web tab ever sees it. The child just gets `the user rejected tool "bash"` and has to report the limitation. So "all agents" means all root agents, and that's all there is to own.
- **Caveat: ordering is listener-registration order, and the web profile already has an answerer.** Under `dsh web`, the gateway's Remote forwarder (`dsh-api-remotes`, shown as `other(Include)`) is an `approval/request` listener. It forwards to browser tabs and **holds the request even when no tab is open**. Whoever is first in the chain owns the request:
  - **append** (plain `ctx.on`): the plugin never sees a request, because the web forwarder holds it first.
  - **prepend**: the plugin owns it. The web UI sees nothing: no pending event, and `sessionController.state().pendingInput` is empty, so the desktop browser just shows a running task.
  - **prepend + fan-out** (recommended): the plugin parks the request, then re-dispatches a copy down the rest of the chain with its own abort signal. The first answer wins, and the other copy is withdrawn. The web shows "input required" (`pendingInput: ['approval']`). If the phone answers first, the open tab gets a `cancel` frame for its copy. If the web answers first, the plugin's parked entry settles with the web's outcome. Either way the session log gets exactly one `approval/asked` / `approval/decided` pair.

  The upstream README says a deployment composes "one terminal answerer" and that sibling order "is not a policy-priority mechanism". So relying on `prepend` uses the seam a little outside its stated contract. It works in `0.2.2-rc.1`; S12 (upstream guard) should pin it with a test.

## ARCHITECTURE.md changes this implies

- **§1, approvals row:** the claim "No answering client ⇒ immediately `unavailable`" is wrong for `dsh web`. With no browser tab open, the gateway forwarder holds the request indefinitely and delivers it when a tab connects (scenario J). `unavailable` happens only when no terminal answerer is composed at all. Corrected there (confirmed by the user on 2026-11-05).
- **§5.4 approval holder:** register **prepend + fan-out**, recorded as **D17** (confirmed by the user on 2026-11-05), with the alternatives considered.
- **§8.1:** marked as answered by X1 (confirmed by the user on 2026-11-05).

## What a held request looks like

`request` (the waterfall argument) has `agent` (the live Agent; `agent.session.id` is the DSH session id), `toolName`, `callId`, `reason`, `signal`, and optionally `displayReason`. `callId` equals the `tool/call` event's `callId`, so the bridge can join the request with the streamed tool call and its arguments to describe impact. The answer is one of `allowed-once`, `rejected`, `cancelled`, `unavailable`. DSH writes `approval/asked` and then `approval/decided` into the session log itself. The bridge's own audit (which device answered) is extra.

## Run it

```sh
spikes/x1-approval/scripts/run                  # all scenarios, writes results/latest.json
node spikes/x1-approval/release.mjs list        # while a scenario holds one: see parked approvals
node spikes/x1-approval/release.mjs first allow # release it (allow | reject); the phone's AnswerApproval
```

Needs `~/.dshm/runtime` (DSH + mock server, see PLAN.md T0 Log), Node ≥ 24.9 and a `pnpm` on PATH (the script finds both). Ports: DSH web 3282, mock proxy 47804, plugin control 47803. The run adds the plugin to the `web` profile of `~/.dshm/home-x1x4`.

## Layout

| Path | What |
|---|---|
| `plugin/index.js` | The answerer (modes `off` / `append` / `prepend` / `fanout`), a `tools/pre-execute` gate that asks for any call whose arguments contain `X1-GATE`, a loopback control server, and an in-process stand-in for a browser tab on the gateway's forwarded-event stream. |
| `release.mjs` | Lists and releases parked approvals over the control port. |
| `run.mjs` | Scenarios A–L, 36 checks. |
| `lib/host.mjs` | Starts DSH + plugin(s) + the mock LLM behind a routing proxy (also used by X4). Side calls such as titles go to a fixed mock; agent-loop requests go to per-scenario scripted mocks. |
| `results/latest.json` | Last run: every scenario's observations and checks. |

## Results (36/36)

| | Answerer | Observed |
|---|---|---|
| A | none | Held as a pending web event with no tab open. Nothing answers it in 1.5 s; `pendingInput: ['approval']`. Cancelling the turn settles it `cancelled`. |
| B | append | Order: web forwarder, then plugin. The plugin never sees the request. |
| C | prepend | Order: plugin first. Parks with `toolName`, `callId`, `reason`. The web sees nothing, and the turn stays open. The release script answers `allowed-once`, which is recorded, and the tool runs. |
| D | prepend | Release `rejected`: recorded, and the model gets `the user rejected tool "bash"`. |
| E | prepend | A real `bash` `danger-full-access` escalation (no spike gate) reaches the plugin; after release the command runs. |
| F | fan-out | Plugin parks it, and the web holds a copy too (`pendingInput: ['approval']`). The phone answers, and the web copy is withdrawn. One audit pair. |
| G | prepend | Turn cancelled while parked: `request.signal` aborts, and the entry is dropped as `cancelled`. |
| H | prepend | A subagent's gated call: no answerer is entered and the web gets nothing; the child gets a plain rejection (policy `never`). |
| J | none | A tab opening *after* the request was held receives it on connect, answers it, and the tool runs. |
| K | fan-out, tab open | The web answers `rejected` first. The plugin's parked entry settles `rejected` (`answeredBy: downstream`). One audit pair. |
| L | fan-out, tab open | The phone answers first, and the tab receives a `cancel` for its copy. One audit pair. |

## Gotchas for S4

- **Fan-out re-entry.** The copy goes through `ctx.waterfall(this, 'approval/request', copy, () => 'unavailable')`, where `this` is the dispatch carrier. That re-enters the chain at its head, so the answerer must recognize its own copy and call `next()`; the spike uses a `WeakSet`. **Don't mark the copy with a symbol key:** the gateway rejects a request with any non-JSON own property ("Remote event request has a non-JSON property"), and the web copy silently never appears.
- **Downstream `unavailable` means "no one else", not "deny".** Keep holding. In a profile without the web forwarder, the copy returns `unavailable` immediately.
- **No DSH timeout.** The bridge's timeout (§5.4) has to settle the request itself, with `rejected`, never allow (principle 5), and abort the downstream copy.
- **Web-UI-only state.** In fan-out mode, a tab that closes and reopens gets the held copy again (scenario J's mechanism). A tab that *declines* (returns `next`) passes it on down the chain. Nothing in our holder has to change for either.

## Not covered

- **The DSH desktop app** (not installed here). It is expected to use the same gateway forwarder as web, but that's unverified.
- **A real browser tab.** Scenarios J–L use an in-process owner client on the same gateway stream the web UI uses (`openRemoteEvents`), not Chromium.
- **Real-model behavior** after a rejection.
