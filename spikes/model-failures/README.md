# X1 (M2) · Spike: model failures in DSH: conclusion

Working note for PLAN.md X1 (feeds S3, issue #4). Measured on 2026-11-08 against DSH `0.2.2-rc.1` (`dsh web`, `DSH_HOME=~/.dshm/home-x1`), with a fake DeepSeek provider in front of DSH's mock LLM. Delete this folder once S3 has acted on it (move the fixtures it replays first, see [Fixtures](#fixtures)).

## Answer

**DSH never pauses. A provider failure ends the turn with an error, after retries for a rate limit only. The session stays usable: a new message runs a new turn normally.**

Every failure reaches the bridge the same way, on `sessionController.follow`:

1. an `assistant-stream` chunk `{ type: 'finish', reason: { kind: 'error', failure: { message, code, status } } }`,
2. a durable `assistant/attempt` event with the same failure (no `assistant/message`),
3. for a retryable code, `llm/retry` (+ `llm/retry-started`) and the step runs again,
4. `step/end`, then **`turn/end { turn, reason: { kind: 'error', error: { message, code, status } } }`**.

`code` is DSH's stable failure class (`HarnessError.code`; DSH says "route on this, never by parsing `message`"). `message` is the provider's `error.message`, unchanged.

| Failure | Provider answer (fake) | `code` | DSH does | Time to `turn/end` | `message` | DSH web shows (zh / en) |
|---|---|---|---|---|---|---|
| Model not found | 404 `not_found_error` "Model Not Exist" | `HTTP_404` | ends the turn | ~0.3 s | `Model Not Exist` | 本轮运行失败 / This turn failed · `Model Not Exist` · `HTTP_404` |
| Model not found (DeepSeek's OpenAI-endpoint wording) | 400 `invalid_request_error` "Model Not Exist" | `INVALID_REQUEST` | ends the turn | ~0.3 s | `Model Not Exist` | … `Model Not Exist` · `INVALID_REQUEST` |
| Model the host does not list | none: `selectModel` refuses before the prompt | `session/model-unavailable` (an RPC error, not a turn) | refuses the selection; the session keeps its model | — | `Select an available model before sending a message.` | — (web's picker only offers listed models) |
| Key not valid | 401 `authentication_error` "Authentication Fails, Your api key: ****-key is invalid" | `AUTH` | ends the turn | ~0.3 s | the provider text | 本轮运行失败 · **API 密钥无效** / **API key is invalid** · `AUTH` |
| No balance | 402 "Insufficient Balance" | `QUOTA` | ends the turn | ~0.3 s | `Insufficient Balance` | 本轮运行失败 · **当前请求的额度已用尽** / **Request quota exhausted.** · `QUOTA` |
| Rate limited, does not clear | 429 `rate_limit_error` "Rate Limit Reached", no `Retry-After` | `RATE_LIMIT` | **retries 5 times in the same turn**, then ends it | ~16 s | `Rate Limit Reached` | 已重试模型请求（5/5）· 9s, then 本轮运行失败 · `Rate Limit Reached` · `RATE_LIMIT` |
| Rate limited, clears | 429 twice with `Retry-After: 2`, then 200 | — | retries twice (2000 ms each, the provider's value), then the turn completes | ~4.4 s (completed) | — | the retry row, then the answer |

Screens: [`web/no-balance.jpg`](web/no-balance.jpg), [`web/invalid-key.jpg`](web/invalid-key.jpg), [`web/rate-limit.jpg`](web/rate-limit.jpg).

### Retries

- Policy: `@deepseek-ai/dsh-llm-retry` is in DSH's base bundle; the DeepSeek route has no `retryPolicy`, so the default "normal" mode applies: **5 retries** for `RATE_LIMIT`, `SERVER`, `TIMEOUT`, `TRANSPORT`, `EMPTY_RESPONSE`. Backoff 500 ms doubling, at most 10 s, ±10 % jitter. A valid `Retry-After` replaces it.
- Measured (persistent 429): delays 483, 927, 2140, 3852, 8550 ms; `turn/end` at 16.4 s after the prompt (another run: 15.8 s).
- `AUTH`, `QUOTA`, `INVALID_REQUEST`, `HTTP_404` are **not** retried: the turn ends after one request.
- Each `llm/retry` carries `{ retry, maxRetries, mode, delayMs, failure: { message, code, status } }`. The bridge can show "retrying (n/5)" from it; S3 doesn't need to.

### Text the phone can show (D104, provisional)

- Route on `turn/end.reason.error.code`, like DSH web (`dsh-client-ui-chat` `failureMessage`): `AUTH` → its own copy (DeepSeek's 401 text names a masked key), `QUOTA` / `ACCOUNT_QUOTA` → its own copy ("insufficient balance" in the user's language). Every other code: show `message` as it is, with the code as a small tag.
- `message` is the provider's English text. For DeepSeek it's short and fit to show ("Model Not Exist", "Insufficient Balance", "Rate Limit Reached").
- Today's bridge (`describeFailure`) sends `"error: <message>"` and drops `code`. S3 should carry `code` to the app (D104).

### A new message after the failure

Tested for every terminal case: after the failure, the provider is healed and a `steer` prompt goes into the same session. DSH accepts it at once (`{ accepted: true }`), starts turn 2, and the turn completes normally (~0.8 s with the mock). The failed turn 1 writes no `assistant/message` (only `assistant/attempt`), so the history holds the two user messages and no failed output (per the dsh-llm-retry README, failed attempts never reach the model; the request body itself was not checked). This is S3's "top up, then send a new message" path, and it needs nothing beyond D89's follow-up.

### Making each case in tests

- **DSH's mock LLM** (`@deepseek-ai/dsh-llm-mock-server`) has `auth_error` (401 → `AUTH`), `quota_exceeded` (429 "insufficient quota" → `QUOTA`, by text), `rate_limit` (429 + `Retry-After` → `RATE_LIMIT`, retried), `invalid_request` (400 → `INVALID_REQUEST`), `server_error` / `service_unavailable`. Verified by the `mock-*` cases. It has **no 402 and no 404**, and its texts are "mock …".
- **The fake provider** (`fake-provider.mjs`, ~70 lines) answers any status, headers and body, then forwards to the mock for success. Use it for the exact DeepSeek cases (402, 404) and for S3's demo ("no balance", then the top-up: `set(null)`).
- **The bridge test (S3)** doesn't need DSH: replay a fixture's `frames` through `FakeDSH`'s follow.

## Fixtures

`fixtures/<case>.json`, one per case, written by the run. Each one has:

- `provider`: the scripted answer (status, headers, body, scope); `selection` / `selected` for `model-unlisted`;
- `providerRequests`: every request DSH made (time from the prompt, agent loop or side call such as the session title, status);
- `frames`: **every `sessionController.follow` frame, unchanged**, each with `atMs` from the prompt. Turn 1 fails; for the terminal cases turn 2 is the follow-up that completes. The opening snapshot is reduced to `{ type: 'snapshot' }`, and bulk prompt text (system prompt, tool schemas, local skills, paths of this Mac) is elided.

| Case | File | Turn 1 ends |
|---|---|---|
| Model not found (404) | `model-not-found.json` | `HTTP_404` |
| Model not found (400) | `model-not-exist-400.json` | `INVALID_REQUEST` |
| Unlisted model | `model-unlisted.json` | completed (`selected` is the refusal) |
| Key not valid | `invalid-key.json` | `AUTH` |
| No balance | `no-balance.json` | `QUOTA` |
| Rate limit, persistent | `rate-limit.json` | `RATE_LIMIT` after 5 `llm/retry` |
| Rate limit, clears | `rate-limit-recovers.json` | completed after 2 `llm/retry` |
| Mock `auth_error` / `quota_exceeded` / `invalid_request` | `mock-*.json` | `AUTH` / `QUOTA` / `INVALID_REQUEST` (no follow-up) |

**Where they go:** S3 copies the fixtures its bridge test replays into `bridge/test/fixtures/model-failures/` (code must not refer to this working folder). They stay here until then, because the frame shape S3's `FakeDSH` replay wants is S3's choice.

## Run it

```sh
spikes/model-failures/run.sh                 # all cases (~40 s); writes fixtures/ and results/latest.json
spikes/model-failures/run.sh no-balance      # one case
spikes/model-failures/run.sh --keep          # then leave DSH web up and print its URL
```

Needs `~/.dshm/runtime` (DSH + mock server), Node >= 24.9, a pnpm on PATH. Ports (X1's slot): fake provider 47811, plugin control 47841, DSH web 3284. The run adds the plugin to the `web` profile of `~/.dshm/home-x1`.

| Path | What |
|---|---|
| `run.sh`, `run.mjs` | The cases, the DSH host, the recording |
| `fake-provider.mjs` | Fake DeepSeek Messages endpoint: scripted errors, else DSH's mock |
| `plugin/` | Starts a task the way the bridge does and records every follow frame |
| `results/latest.json` | Summary of the last run: per case `turn/end`s, `llm/retry`s, requests |

## Not covered

- **Real DeepSeek wording.** The bodies follow DeepSeek's documented error codes (OpenAI-style envelope); the Anthropic-compatible endpoint DSH uses may word them differently. DSH classifies by HTTP status first, so the `code` holds; only `message` may differ.
- **Failures mid-task** (after tool calls or streamed text): the same `turn/end` path, not recorded.
- **DeepSeek account sign-in** (`ACCOUNT_QUOTA`, `ACCOUNT_SIGN_IN_REQUIRED`): the API-key route only.
- **The quota toast** DSH web raises on a live `QUOTA` end: not seen in the screens (they were opened after the turn).
