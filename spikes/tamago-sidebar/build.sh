#!/bin/zsh
# Builds build/TamagoInMeum.app: Tamago's five sidebar sources, copied VERBATIM from the Tamago repo
# (only read there, never written), compiled against the local CmuxExtensionKit shim, plus the meum
# host (the floating layout). Fails if a vendored file differs from the repo's working tree.
set -euo pipefail
HERE=${0:A:h}
TAMAGO=${TAMAGO:-$HOME/code/tamago}
cd $HERE
SRC=(TamagoSidebarExtension SidebarModel SidebarView Pet DaemonClient)

mkdir -p vendor/tamago build/obj
for f in $SRC; do cp $TAMAGO/extension/Sources/$f.swift vendor/tamago/$f.swift; done
cp $TAMAGO/sidebar/species.json vendor/tamago/species.json
for f in $SRC; do cmp -s $TAMAGO/extension/Sources/$f.swift vendor/tamago/$f.swift || { echo "vendored $f differs" >&2; exit 1; }; done
{
  echo "tamago HEAD $(git -C $TAMAGO --no-optional-locks rev-parse --short HEAD)"
  echo "uncommitted in the copied files (working tree was copied as is):"
  git -C $TAMAGO --no-optional-locks diff --stat HEAD -- extension/Sources sidebar/species.json | sed 's/^/  /'
  (cd vendor/tamago && shasum -a 256 *.swift species.json)
} > vendor/PROVENANCE.txt

T=$(uname -m)-apple-macos14.0
echo "compiling CmuxExtensionKit shim"
xcrun swiftc -target $T -O -swift-version 5 -parse-as-library \
  -module-name CmuxExtensionKit -emit-library -static -emit-module \
  -emit-module-path build/obj/CmuxExtensionKit.swiftmodule -o build/obj/libCmuxExtensionKit.a \
  Shim/CmuxExtensionKit.swift

echo "compiling Tamago (unchanged) + meum host"
APP=build/TamagoInMeum.app
rm -rf $APP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
xcrun swiftc -target $T -O -swift-version 5 -parse-as-library \
  -module-name TamagoInMeum -I build/obj -L build/obj -lCmuxExtensionKit \
  -o $APP/Contents/MacOS/TamagoInMeum \
  vendor/tamago/*.swift Host/MeumHost.swift

cp vendor/tamago/species.json fixtures/snapshot.json fixtures/state.json $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>com.max.meum.tamago-sidebar-spike</string>
  <key>CFBundleName</key><string>TamagoInMeum</string>
  <key>CFBundleExecutable</key><string>TamagoInMeum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
echo "built $APP"
