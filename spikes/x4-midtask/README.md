# X4 · Spike: mid-task context: conclusion

Working note for PLAN.md X4 (answers ARCHITECTURE §8.6, feeds the M2 mid-task context slice). Archive it to `.archive/YYYYMMDD/x4-midtask.md` once that slice has acted on it. Measured on 2026-11-05 against DSH `0.2.2-rc.1` (`dsh web`, mock LLM, `DSH_HOME=~/.dshm/home-x1x4`).

## Answer

**Yes: a running session accepts new messages, and the caller chooses queue or inject.** `ctx.sessionController.prompt({ requestId, sessionId, mode, content })` returns `{ accepted: true }` immediately while a turn runs. This is the same call the bridge already uses for `CreateTask`, so no new seam is needed.

| `mode` | Inbox target | When the agent sees it |
|---|---|---|
| `steer` | `next-step` | **Injected into the current turn** at the next step boundary: after the running tool returns, or after the current model response finishes streaming. It doesn't interrupt either. On an idle session it starts a new turn. |
| `queue` | `next-turn` | **Queued.** It runs as a new turn after the current turn ends. |

While pending, both show up in `sessionController.state().queue` with `placement: 'steering'` or `'queued'` and their `rpcId` (= our `requestId`). The app can show "will be read at the next step" or "queued" honestly, and dedupe retries: per the session-controller README, a repeated `requestId` returns the original acceptance (not tested here).

**Attachments work mid-task, the same way as in a first prompt.**
- **File:** stage the bytes with `ctx.fileUploads.uploadStream({ sessionId, data, name })` → `receiptId`, then send `{ type: 'file', receiptId }`. The model gets a text note with the name, size, sha256 and a read-only saved path under `DSH_HOME/attachments/`. It doesn't get the contents; it reads the path with its file tools.
- **Image:** send `{ type: 'image', mediaType, data: <base64> }` inline. The model gets an `image` block plus a note with the normalized copy's path.

Both were accepted in a `steer` and reached the model in the same turn's next step. A real non-vision model route may refuse images ("image-input check"). That's unverified here, and the bridge must map such a refusal to a typed error.

**Agent questions surface on their own seam, distinct from approvals.** The `ask_user_question` tool calls `ctx.userQuestions.ask()`, which dispatches the **`user-questions/request`** waterfall (approvals use `approval/request`).
- **Holding works like approvals.** The web forwarder holds the question with no tab open, and `sessionController.state().pendingInput` says `['question']`, where an approval says `['approval']`. A prepended plugin answerer parks it the same way, and the web then sees nothing. The same prepend + fan-out holder as X1/D17 applies.
- **Request:** `{ questions, agent, signal }`, with no `callId`. Each question has `id`, `question`, `header`, `options[{label, description}]`, and optional `multiSelect` / `intent`. The questions carry everything needed for display, so no join with the tool call is needed.
- **Answer:** `{ answers: [{ id, selected: [labels], custom? }] }`. The model gets it verbatim as the tool result. An empty `selected` with no `custom` means "skipped".
- **A steer sent while a question waits doesn't release it.** It lands in the step after the answer. To unblock the agent, the user answers the question (or cancels the turn).
- **Only root agents can ask.** A subagent gets `DELEGATED_CALLER` and has to put the question in its final result. As with approvals, there's nothing to hold for subagents.
- **Timed mode** (`askTimed`, off in shipped presets) lets the agent continue after a deadline. A later answer then arrives as a `user-question-reply` message steered in through the `userQuestions` `answer` Remote method. Not exercised here.

## ARCHITECTURE.md changes this implies

- **§1, mid-task context row:** now verified (steer vs queue, attachments, question seam). Marked provisional.
- **§8.6:** marked as answered by X4 (provisional).
- **D18** (*provisional, pending user confirmation*):
  - The facade exposes `SendMessage { task_id, mode: STEER | QUEUE, parts }`. The app defaults to `STEER`, because a follow-up written while the agent works is meant for this task now.
  - Agent questions go through the same bridge holder as approvals, as their own `QuestionPending` / `AnswerQuestion` messages, not as approvals.

## Run it

```sh
spikes/x4-midtask/scripts/run     # all scenarios, writes results/latest.json
```

Same needs as X1 (it reuses `spikes/x1-approval/lib/host.mjs`). Ports: DSH web 3282, mock proxy 47804, plugin control 47805. The run adds the plugin to the `web` profile of `~/.dshm/home-x1x4`.

## Layout

| Path | What |
|---|---|
| `plugin/index.js` | Loopback control server. Creates tasks, sends `steer` / `queue` prompts with optional file or image parts, and parks `user-questions/request` with a prepended answerer. |
| `run.mjs` | Scenarios 1–5b, 19 checks. Placement is read from the session log (`agent/inbox/spliced`, `user/message` against `turn/start` / `step/start`). Arrival is read from the model requests the mock proxy saw. |
| `results/latest.json` | Last run: every scenario's observations and checks. |

## Results (19/19)

| | Setup | Observed |
|---|---|---|
| 1 | `steer` + `queue` while a `bash sleep 4` runs (turn 1, step 1) | Both accepted at once. The steer is logged in turn 1 step 2 and is in the 2nd model request. The queued message is logged in turn 2, step 1, and is not in turn 1's requests. |
| 2 | `steer` while the model streams | The stream isn't cut off (no `interrupted`). The steer runs as turn 1 step 2. |
| 3 | `steer` into an idle session | It starts turn 3. |
| 4 | `steer` with a staged text file, then with an inline PNG, during a tool call | Both accepted. Step 2 holds the text, the file note (saved path, no contents), the image note, and an `image` block. |
| 5a | `ask_user_question`, no plugin answerer | Held as a pending web `user-questions/request`; `pendingInput: ['question']`. |
| 5b | The same with a prepended plugin answerer, plus a steer while it waits | Parked with its questions and options; the web sees nothing. The steer doesn't release it. The answer reaches the model as the tool result, and the steer follows in step 2. |

## Not covered

- **Real-model behavior** (how an agent actually reacts to a steer).
- **Image refusal** on a non-vision route.
- **Timed questions.**
- **`intent: approval` / `plan-review` question presentations.**
- **Editing or removing a queued message.** `sessionController` has queue-edit methods, but they weren't tried.
- **Steer into a subagent.** A live child accepts queue actions per the session-controller README, but that wasn't tried.
