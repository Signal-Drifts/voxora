#!/usr/bin/env bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$project_dir/.build/release"
dist_dir="$project_dir/dist"
app_dir="$dist_dir/Voxora.app"
contents_dir="$app_dir/Contents"
dmg_stage_dir="$dist_dir/dmg-stage"
swift_cache_dir="$project_dir/.build/tool-cache"
asset_catalog="$project_dir/Resources/Assets.xcassets"
signing_identity="${SIGNING_IDENTITY:-}"

next_release=1
for existing_dmg in "$dist_dir"/Voxora-1.*.dmg; do
    [[ -e "$existing_dmg" ]] || continue
    filename="$(basename "$existing_dmg")"
    minor="${filename#Voxora-1.}"
    minor="${minor%.dmg}"
    if [[ "$minor" =~ ^[0-9]+$ ]] && (( minor >= next_release )); then
        next_release=$((minor + 1))
    fi
done
version="1.$next_release"
dmg_path="$dist_dir/Voxora-$version.dmg"

if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

export CLANG_MODULE_CACHE_PATH="$swift_cache_dir/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$swift_cache_dir/swiftpm-modules"

if [[ -z "$signing_identity" ]]; then
    signing_identity="$(security find-identity -v -p codesigning 2>/dev/null \
        | sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p' \
        | head -n 1)"
fi
if [[ -z "$signing_identity" ]]; then
    signing_identity="-"
fi

cd "$project_dir"
swift build -c release \
    --disable-sandbox \
    --cache-path "$swift_cache_dir/packages" \
    --config-path "$swift_cache_dir/config" \
    --security-path "$swift_cache_dir/security" \
    --scratch-path "$project_dir/.build"

rm -rf "$app_dir" "$dmg_stage_dir"
mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$build_dir/ConsentCallRecorder" "$contents_dir/MacOS/ConsentCallRecorder"
cp "$project_dir/Resources/Info.plist" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $version" "$contents_dir/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $next_release" "$contents_dir/Info.plist"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    xcrun actool "$asset_catalog" \
    --compile "$contents_dir/Resources" \
    --platform macosx \
    --minimum-deployment-target 14.0 \
    --app-icon AppIcon \
    --output-partial-info-plist "$swift_cache_dir/asset-info.plist" \
    >/dev/null

if [[ "$signing_identity" == "-" ]]; then
    codesign --force --deep --sign - --identifier com.harishgupta.Voxora "$app_dir"
else
    codesign \
        --force \
        --deep \
        --options runtime \
        --timestamp \
        --sign "$signing_identity" \
        --identifier com.harishgupta.Voxora \
        "$app_dir"
fi

mkdir -p "$dmg_stage_dir"
cp -R "$app_dir" "$dmg_stage_dir/Voxora.app"
ln -s /Applications "$dmg_stage_dir/Applications"
rm -f "$dmg_path"
hdiutil create \
    -volname "Voxora" \
    -srcfolder "$dmg_stage_dir" \
    -ov \
    -format UDZO \
    "$dmg_path"
rm -rf "$dmg_stage_dir"

if [[ "$signing_identity" != "-" ]]; then
    codesign --force --timestamp --sign "$signing_identity" "$dmg_path"
fi

echo "Signed with: $signing_identity"
echo "Version: $version"
echo "$app_dir"
echo "$dmg_path"
