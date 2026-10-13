#!/bin/zsh
# 월급티커 메뉴막대 앱 빌드 → ./build/월급티커.app (Apple Silicon + Intel 유니버설)
# ./build.sh zip      → ./build/SalaryTicker.zip (임시 서명)
# ./build.sh release  → Developer ID 서명 + Apple 공증 + 스테이플 후 ./build/SalaryTicker.zip
#   공증 자격: NOTARY_KEY(.p8 경로)·NOTARY_KEY_ID·NOTARY_ISSUER 환경변수, 없으면 키체인 프로필
#   NOTARY_PROFILE(기본 salaryticker-notary, `xcrun notarytool store-credentials`로 저장)
set -e
cd "$(dirname "$0")"
VERSION="1.1.0"
APP="build/월급티커.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -target $arch-apple-macos14.0 SalaryTicker.swift -o "build/SalaryTicker-$arch"
done
lipo -create build/SalaryTicker-arm64 build/SalaryTicker-x86_64 -output "$APP/Contents/MacOS/SalaryTicker"
rm build/SalaryTicker-arm64 build/SalaryTicker-x86_64
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>월급티커</string>
  <key>CFBundleDisplayName</key><string>월급티커</string>
  <key>CFBundleIdentifier</key><string>com.younkyumjin.salaryticker</string>
  <key>CFBundleExecutable</key><string>SalaryTicker</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
if [[ "$1" == "release" ]]; then
  IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
  codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  rm -f build/SalaryTicker.zip
  ditto -c -k --keepParent "$APP" build/SalaryTicker.zip
  if [[ -n "$NOTARY_KEY" ]]; then
    AUTH=(--key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER")
  else
    AUTH=(--keychain-profile "${NOTARY_PROFILE:-salaryticker-notary}")
  fi
  xcrun notarytool submit build/SalaryTicker.zip "${AUTH[@]}" --wait
  xcrun stapler staple "$APP"
  rm -f build/SalaryTicker.zip
  ditto -c -k --keepParent "$APP" build/SalaryTicker.zip
  spctl -a -vv "$APP"
  echo "공증 완료: $PWD/build/SalaryTicker.zip"
  exit 0
fi

codesign --force --sign - "$APP"
echo "빌드 완료: $PWD/$APP"

if [[ "$1" == "zip" ]]; then
  rm -f build/SalaryTicker.zip
  ditto -c -k --keepParent "$APP" build/SalaryTicker.zip
  echo "압축 완료: $PWD/build/SalaryTicker.zip"
fi
