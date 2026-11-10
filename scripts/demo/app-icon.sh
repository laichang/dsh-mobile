#!/bin/bash
# Demo and checks: the app has an icon in each iOS appearance (design/icon.svg).
# The bug: AppIcon.appiconset had slots and no images, so the built app had no icon and iOS showed
# a blank one. This builds the app and checks the built bundle, not the source files:
#   - Info.plist has CFBundleIcons › CFBundlePrimaryIcon › CFBundleIconName = AppIcon
#   - the compiled Assets.car has AppIcon renditions in the default, dark and tinted appearances
#   - the source PNGs are 1024×1024 and the default one has no alpha channel
#
#   scripts/demo/app-icon.sh          build and check
#   scripts/demo/app-icon.sh --shots  also install the app and save Home Screen screenshots in light and
#                                dark mode to evidence/app-icon/ (1/2 size)
#
# Resources (WORKFLOW.md §6), from the environment (`eval "$(scripts/slice-env <ID>)"`):
#   DSHM_SIM dshm-app-icon   DSHM_DD (DerivedData) /tmp/dshm-app-icon-dd
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
SHOTS=0
for a in "$@"; do
  case "$a" in
    --shots) SHOTS=1 ;;
    *) echo "unknown arg $a" >&2; exit 2 ;;
  esac
done
export DSHM_SIM="${DSHM_SIM:-dshm-app-icon}" DSHM_DD="${DSHM_DD:-/tmp/dshm-app-icon-dd}"
SIM="$DSHM_SIM"
LOGS=/tmp/dshm-s25
mkdir -p "$LOGS"
step() { printf '\n== %s\n' "$*"; }
fail() { echo "app-icon: $*" >&2; exit 1; }
if [[ "$SIM" =~ ^[0-9A-F-]{36}$ ]]; then DEST="platform=iOS Simulator,id=$SIM"; else DEST="platform=iOS Simulator,name=$SIM"; fi
source scripts/demo/lib.sh

step "source PNGs (ios/dsh-mobile/Assets.xcassets/AppIcon.appiconset)"
SET=ios/dsh-mobile/Assets.xcassets/AppIcon.appiconset
for f in AppIcon AppIcon-dark AppIcon-tinted; do
  [ -f "$SET/$f.png" ] || fail "$SET/$f.png is missing (scripts/render-icon writes it)"
  info=$(sips -g pixelWidth -g pixelHeight -g hasAlpha "$SET/$f.png")
  printf '%s\n' "$info" | grep -q 'pixelWidth: 1024' && printf '%s\n' "$info" | grep -q 'pixelHeight: 1024' \
    || fail "$f.png is not 1024×1024"
  echo "$f.png 1024×1024 alpha=$(printf '%s\n' "$info" | awk '/hasAlpha/ {print $2}')"
done
sips -g hasAlpha "$SET/AppIcon.png" | grep -q 'hasAlpha: no' || fail "AppIcon.png has an alpha channel"

step "Release build of the app ($SIM)"
scripts/xc build -project ios/dsh-mobile.xcodeproj -scheme dsh-mobile -configuration Release \
  -destination "$DEST" -derivedDataPath "$DSHM_DD" ONLY_ACTIVE_ARCH=YES \
  -onlyUsePackageVersionsFromResolvedFile -skipPackageUpdates --log "$LOGS/build.log" \
  || { grep -E 'error:|failed' "$LOGS/build.log" | tail -20; fail "build failed"; }
APP="$DSHM_DD/Build/Products/Release-iphonesimulator/dsh-mobile.app"
[ -d "$APP" ] || fail "no app at $APP"
if grep -E "warning: .*AppIcon" "$LOGS/build.log"; then fail "the asset catalog warns about AppIcon"; fi

step "Info.plist names the icon"
name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIcons:CFBundlePrimaryIcon:CFBundleIconName' "$APP/Info.plist" 2>/dev/null) \
  || fail "Info.plist has no CFBundleIcons › CFBundlePrimaryIcon › CFBundleIconName"
[ "$name" = AppIcon ] || fail "CFBundleIconName is '$name', not AppIcon"
echo "CFBundleIconName = $name"

step "Assets.car has the AppIcon renditions (default, dark, tinted)"
[ -f "$APP/Assets.car" ] || fail "no Assets.car in the app"
xcrun assetutil --info "$APP/Assets.car" > "$LOGS/assets.json"
# One line per AppIcon rendition: "<appearance> <pixel width>". assetutil names the appearance
# NSAppearanceNameDarkAqua for dark and ISAppearanceTintable for tinted; none for default.
/usr/bin/python3 -I - "$LOGS/assets.json" > "$LOGS/renditions.txt" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1])):
    if r.get("Name") != "AppIcon" or "PixelWidth" not in r:
        continue
    print(r.get("Appearance", "default"), r["PixelWidth"])
PY
sort -u "$LOGS/renditions.txt" | sed 's/^/  /'
grep -q '^default ' "$LOGS/renditions.txt" || fail "no default AppIcon rendition"
grep -qi 'dark' "$LOGS/renditions.txt" || fail "no dark AppIcon rendition"
grep -qi 'tint' "$LOGS/renditions.txt" || fail "no tinted AppIcon rendition"

if [ $SHOTS = 1 ]; then
  step "Home Screen screenshots, light and dark → ${DSHM_EVIDENCE:-evidence/app-icon} (1/2 size)"
  xcrun simctl bootstatus "$SIM" -b >/dev/null
  xcrun simctl install "$SIM" "$APP"
  # A new app goes to the last Home Screen page. Put it in the dock, which every page shows: edit
  # SpringBoard's IconState.plist while the simulator is shut down, then boot it again.
  data=$(xcrun simctl list devices -j | /usr/bin/python3 -I -c '
import json, sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if sys.argv[1] in (d["name"], d["udid"]): print(d["dataPath"])' "$SIM" | head -1)
  icons="$data/Library/SpringBoard/IconState.plist"
  for _ in $(seq 1 30); do grep -q chang.dsh-mobile "$icons" 2>/dev/null && break; sleep 1; done
  xcrun simctl shutdown "$SIM"
  /usr/bin/python3 -I - "$icons" <<'PY'
import plistlib, sys
p = sys.argv[1]
s = plistlib.load(open(p, "rb"))
app = "chang.dsh-mobile"
s["iconLists"] = [[i for i in page if i != app] for page in s.get("iconLists", [])]
s["iconLists"] = [page for page in s["iconLists"] if page] or [[]]
s["buttonBar"] = [i for i in s.get("buttonBar", []) if i != app] + [app]
plistlib.dump(s, open(p, "wb"), fmt=plistlib.FMT_BINARY)
PY
  dshm_quiet_sim "$SIM"
  sleep 8   # SpringBoard lays out the Home Screen after the boot
  mkdir -p ${DSHM_EVIDENCE:-evidence/app-icon}
  for mode in light dark; do
    xcrun simctl ui "$SIM" appearance "$mode"
    sleep 8   # SpringBoard redraws the icons after the change
    xcrun simctl io "$SIM" screenshot "$LOGS/home-$mode.png" >/dev/null 2>&1
    out="${DSHM_EVIDENCE:-evidence/app-icon}/app-icon-home-$mode.png"
    sips --resampleWidth 603 "$LOGS/home-$mode.png" --out "$out" >/dev/null
    echo "$out $(du -h "$out" | cut -f1)"
  done
  xcrun simctl ui "$SIM" appearance light
fi
step "app-icon check passed"
