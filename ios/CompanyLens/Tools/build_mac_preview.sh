#!/bin/bash
# Rebuild the shared native Mac preview; never launches the application.
set -euo pipefail

cfa_project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cfa_configuration="${1:-debug}"
case "$cfa_configuration" in
    debug|release) ;;
    *) printf 'Usage: %s [debug|release]\n' "$0" >&2; exit 2 ;;
esac
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf 'This preview requires macOS.\n' >&2
    exit 2
fi
if ! command -v swift >/dev/null 2>&1; then
    printf 'Swift is unavailable. Apple developer tools are required.\n' >&2
    exit 2
fi

swift build --package-path "$cfa_project_dir" --configuration "$cfa_configuration" --product CompanyLens
cfa_bin_dir="$(swift build --package-path "$cfa_project_dir" --configuration "$cfa_configuration" --show-bin-path)"
cfa_executable="$cfa_bin_dir/CompanyLens"
cfa_resource_bundle="$cfa_bin_dir/CompanyLens_CompanyLens.bundle"
if [[ ! -x "$cfa_executable" || ! -d "$cfa_resource_bundle" ]]; then
    printf 'SwiftPM executable or resource bundle is missing in: %s\n' "$cfa_bin_dir" >&2
    exit 1
fi

cfa_verification_dir="$cfa_project_dir/Verification"
mkdir -p "$cfa_verification_dir"
cfa_preview_stage="$(mktemp -d "$cfa_verification_dir/.mac-preview.XXXXXX")"
cleanup_preview_stage() {
    if [[ -n "$cfa_preview_stage" && -d "$cfa_preview_stage" ]]; then
        /bin/rm -rf "$cfa_preview_stage"
    fi
}
trap cleanup_preview_stage EXIT
cfa_candidate="$cfa_preview_stage/看懂公司-Mac预览.app"
cfa_output_app="$cfa_verification_dir/看懂公司-Mac预览.app"
mkdir -p "$cfa_candidate/Contents/MacOS" "$cfa_candidate/Contents/Resources"
/bin/cp "$cfa_executable" "$cfa_candidate/Contents/MacOS/CompanyLens"
/usr/bin/ditto "$cfa_resource_bundle" "$cfa_candidate/Contents/Resources/CompanyLens_CompanyLens.bundle"
cat > "$cfa_candidate/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleDisplayName</key><string>看懂公司 Mac预览</string>
    <key>CFBundleExecutable</key><string>CompanyLens</string>
    <key>CFBundleIdentifier</key><string>com.companylens.prototype.mac-preview</string>
    <key>CFBundleName</key><string>看懂公司 Mac预览</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
/usr/bin/plutil -lint "$cfa_candidate/Contents/Info.plist"
# iCloud/Finder metadata copied into this generated bundle can invalidate signing.
# Clear it only from the disposable build candidate, never from source reports.
/usr/bin/xattr -cr "$cfa_candidate"
/usr/bin/codesign --force --sign - "$cfa_candidate"
/usr/bin/codesign --verify --strict "$cfa_candidate"

# Replace only this generated preview. Restore it if the final move fails.
if [[ -L "$cfa_output_app" ]]; then
    printf 'Refusing to replace a symlink at the generated application path.\n' >&2
    exit 1
fi
if [[ -e "$cfa_output_app" ]]; then
    /bin/mv "$cfa_output_app" "$cfa_preview_stage/previous.app"
fi
if ! /bin/mv "$cfa_candidate" "$cfa_output_app"; then
    if [[ -d "$cfa_preview_stage/previous.app" ]]; then
        /bin/mv "$cfa_preview_stage/previous.app" "$cfa_output_app"
    fi
    exit 1
fi
printf 'Built Mac preview (not opened):\n%s\n' "$cfa_output_app"
