# Compatibility verification

Baseline `61b54169a58e7a20e9ca243dc96a6739b816e14a`. Candidate `3b85118aaa7c1958665b848296b044f1c370d4c7`. The candidate iOS tree is `a2cc6967006551ea9d310a907a3969b289cb7e19` and the bridge tree is `e4bf5e24edeb3338c6921b7987d27afc0e638ef3`.

## Installed iOS and bridge pairs

Each run removed the previous app container, installed the selected app and paired with a fresh offer through its welcome screen. The drawer reported TLS 1.3. The production command client negotiated `approvals.v1` and `conversation.v2`, resumed the host log, listed tasks, created a task, queued and removed a message, and denied the pending approval. A second replay check verified that approval and queue events appear only for clients advertising the corresponding capabilities.

| iOS revision | Bridge revision | Demo option | XCTest |
| --- | --- | --- | --- |
| `61b54169a58e` | `3b85118aaa7c` | Default | Passed |
| `3b85118aaa7c` | `61b54169a58e` | `--baseline-bridge` | Passed |
| `3b85118aaa7c` | `3b85118aaa7c` | `--current-pair` | Passed |

On the first baseline-client run, XCTest dispatched the pairing link before it observed the welcome controls and timed out at confirmation. After synchronizing link delivery with the welcome screen, all three pairs passed.

## Independent component rollback

Two private local clones started at the candidate. In each clone, the other component stayed at the candidate. For each merge affecting the selected component, in reverse first-parent order, the following commands removed that merge’s component changes and compared the resulting index to its first parent. Each resulting iOS tree passed both a macOS SwiftPM build and a generic iOS Simulator app build. Each resulting bridge tree passed its package build.

```sh
git diff --binary "$merge^1" "$merge" -- "$component" | git apply --reverse --index
git diff --exit-code --cached "$merge^1" -- "$component"
```

| Component | Reversed merge | Verified result tree |
| --- | --- | --- |
| ios | `ea013d8c698b` | `0a1322e6d47a` |
| ios | `bd68cf95b19e` | `c4c62eaf56b9` |
| ios | `11b317c9f8c0` | `307ab11b04c6` |
| ios | `d56f038282db` | `1323634ec473` |
| ios | `95552ff701b1` | `ddba71aa7b51` |
| ios | `badfbafd9bb3` | `b53a4cd3a7fb` |
| ios | `d37d49cb703b` | `aa164ce6f23e` |
| ios | `c12c478cdcbb` | `8e4dc8e32d87` |
| ios | `1b4b54ad5049` | `2ebedf7d6418` |
| ios | `6f593baf4c4c` | `52120b981a85` |
| bridge | `f7380128920b` | `e5fe1588efc4` |
| bridge | `ed5d02ebed44` | `3537eae05908` |

Both final component trees matched the baseline. iOS restored `52120b981a850ad224b7c0fd9a5a6034dbe1ed98` and bridge restored `3537eae05908caa3ae0f964a40a483cdc6ad4c03`.

## Integrated checks

Both language suites decoded the shared golden fixtures, and all 67 tracked fixture files matched the baseline byte for byte. The candidate passed 166 Swift and 99 bridge tests. The paired-device round trip passed all four UI tests, including the real DSH streamed reply. The baseline run recorded 153 Swift, 95 bridge and four UI tests passing. Debug and Release product checks, layer checks, seeded negative layer tests and documentation checks passed on the candidate.
