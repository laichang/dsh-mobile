#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${DSHM_SIM:?set the assigned simulator with scripts/slice-env}"
scripts/slice-env --check-sim "$DSHM_SIM"
source scripts/demo/lib.sh
if xcrun simctl get_app_container "$DSHM_SIM" chang.dsh-mobile data >/dev/null 2>&1; then
  xcrun simctl uninstall "$DSHM_SIM" chang.dsh-mobile
fi
xcrun simctl addmedia "$DSHM_SIM" protocol/fixtures/attachments/photo.jpg
export TEST_RUNNER_DSHM_DURABLE_HOSTS=1 TEST_RUNNER_DSHM_SHOT_DIR="${DSHM_EVIDENCE:-/tmp}"
run_ui() {
  local log="/tmp/dshm-two-hosts-$DSHM_SIM-$2.log"
  scripts/xc "$1" -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile \
    -destination "platform=iOS Simulator,id=$DSHM_SIM" -derivedDataPath "/tmp/dshm-two-hosts-$DSHM_SIM-dd" \
    -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO \
    "-only-testing:dsh-mobileUITests/AttachmentsUITests/$2" --log "$log"
  demo_no_skipped_ui "$log"
}
run_ui test testCreateSessionsOnTwoHosts
container=$(xcrun simctl get_app_container "$DSHM_SIM" chang.dsh-mobile data)
python3 - "$container/Library/Application Support/default.store" <<'PY'
import json
from pathlib import Path
import sqlite3
import sys

with sqlite3.connect(Path(sys.argv[1]).as_uri() + "?mode=ro", uri=True) as db:
    rows = db.execute("""SELECT h.ZNAME, h.ZLASTSEQ, t.ZTASKID, t.ZTITLE, t.ZSESSIONHISTORY,
                         t.ZAPPROVALDATA, t.ZQUEUEDATA, t.ZSENTATTACHMENTSDATA
                         FROM ZCACHEDHOST h JOIN ZCACHEDTASK t ON t.ZHOSTKEY = h.ZKEY
                         WHERE h.ZLOGID = t.ZLOGID ORDER BY h.ZNAME""").fetchall()
    assert [r[0] for r in rows] == ["Home Mac", "Office Mac"], rows and [r[0] for r in rows]
    for host, cursor, task, title, history, approvals, queue, files in rows:
        assert cursor > 0 and task == "shared-1" and title == "Session on " + host
        assert ("Journal on " + host).encode() in history
        assert len(json.loads(approvals)) == 1 and ("Queued for " + host).encode() in queue
        assert json.loads(files)[0]["thumbnail"]
        print(f"{host}: task {task}, cursor {cursor}, saved journal, approval, queue and thumbnail")
PY
run_ui test-without-building testRestoreSessionsOfflineAndReconnect
