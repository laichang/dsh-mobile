#!/bin/bash
# Run on the assigned slice simulator: this test clears its app pairing.
set -euo pipefail
cd "$(dirname "$0")/../.."
: "${DSHM_SIM:?run scripts/slice-env for this slice}"
source scripts/demo/lib.sh
scripts/xc test -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -configuration Debug \
  -destination "platform=iOS Simulator,id=$DSHM_SIM" -derivedDataPath "${DSHM_DD:-/tmp/dshm-unpaired-launch-dd}" \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates -parallel-testing-enabled NO \
  -only-testing:dsh-mobileUITests/FirstRunUITests/testUnpairedLaunchShowsPairing
