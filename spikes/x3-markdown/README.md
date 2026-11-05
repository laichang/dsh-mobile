# X3 · Streaming Markdown on iOS

For S8, retain each completed Markdown block and parse only the open tail when the next chunk arrives. On the iPhone 17 Pro simulator, this reduced p95 update time from 12.80–15.06 ms to 1.14–2.06 ms in the measured run. The choice in D10 is provisional pending the real-device run.

## Reproduce

From the repository root, run `spikes/x3-markdown/run`. The default destination is the iOS simulator named `dshm-X3`; set `DSHM_SIM` to use another installed iPhone simulator. The standalone Swift package uses Xcode 26 and system frameworks. It has no external dependencies.

For the human item, connect an unlocked iPhone running iOS 26 with Developer Mode enabled. Select your Apple account in Xcode and find the phone's identifier in **Window → Devices and Simulators**. From the same checkout run:

```sh
DEVELOPMENT_TEAM=<your-team-id> spikes/x3-markdown/run 'platform=iOS,id=<your-device-identifier>'
```

Replace both placeholders. The command lets Xcode provision the test runner with your team. Keep the device model, OS, six timing rows and the final passing test line. The two X3 `[human]` checkboxes are for the user to accept.

## Workload

The XCTest builds 5,000 lines (47,840 UTF-8 bytes) from 250 numbered coding-task excerpts. They include headings, bold text, inline code, links, Chinese text, fenced Swift with a blank line, diffs and console output. It slices this into 61 updates of up to 767 characters, including updates that end mid-line or mid-token.

Both candidates parse prose with Foundation Markdown, preserve the literal text and language of fenced blocks, and draw the same four-row SwiftUI viewport with `ImageRenderer` on the main actor. **Full** reparses the accumulated source at every update. **Retained** caches completed blocks and reparses only the unfinished block. Each measurement runs from append through rasterization. The test compares every update's visible rows, the final 1,500 blocks, and representative literal code, diff and console text.

## Simulator results

2026-11-05, iPhone 17 Pro simulator, iOS 26.0.1 (23A8464), Release, Xcode 26.0 (17A324), Apple M4 Max. One warm-up draw; order reversed in round 2. Times are milliseconds. Total sums all 61 updates; p95 and max refer to one update.

| Round | Candidate | Total | p95 | Max |
|---|---|---:|---:|---:|
| 1 | Full | 492.72 | 15.06 | 16.06 |
| 1 | Retained | 46.78 | 1.23 | 1.40 |
| 2 | Retained | 43.94 | 1.14 | 1.50 |
| 2 | Full | 482.86 | 13.17 | 17.70 |
| 3 | Full | 466.62 | 12.80 | 13.36 |
| 3 | Retained | 60.18 | 2.06 | 3.80 |

This measures parsing and a 360 × 260 pt viewport. Physical-device timing, live scrolling, very long individual fences and full CommonMark fidelity require separate evaluation. The spike handles the fixture's standalone blocks and triple-backtick fences. S8 owns the production grammar, block views and styles.
