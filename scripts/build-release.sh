#!/bin/zsh
# Release 빌드 → 자체 서명 인증서로 서명 → 서명 검증 → build/Chaja-<버전>.zip 생성
#
#   scripts/build-release.sh            빌드와 zip만
#   scripts/build-release.sh --test     빌드 전에 테스트 실행
#   scripts/build-release.sh --install  빌드 후 이 맥의 /Applications/Chaja.app을 교체하고 실행
#
# 빌드 번호는 git 커밋 수라서, 커밋할 때마다 늘어난다(정보 > 버전에서 확인).
set -euo pipefail

ROOT="${0:A:h:h}"
IDENTITY="Chaja Self-Signed"
DERIVED="$ROOT/build/ReleaseDerivedData"
APP="$DERIVED/Build/Products/Release/Chaja.app"
INSTALL_PATH="/Applications/Chaja.app"

run_tests=false
install=false
for arg in "$@"; do
  case "$arg" in
    --test) run_tests=true ;;
    --install) install=true ;;
    *) echo "알 수 없는 옵션: $arg" >&2; exit 2 ;;
  esac
done

step() { print -P "%F{cyan}▸ $1%f"; }
fail() { print -P "%F{red}✘ $1%f" >&2; exit 1; }

cd "$ROOT"

security find-certificate -c "$IDENTITY" >/dev/null 2>&1 \
  || fail "키체인에 '$IDENTITY' 인증서가 없습니다. docs/handoff.md 0-6 절차로 만드세요."
command -v xcodegen >/dev/null || fail "xcodegen이 없습니다: brew install xcodegen"

if [[ -n "$(git status --porcelain)" ]]; then
  print -P "%F{yellow}! 커밋하지 않은 변경이 있습니다. 빌드 번호는 마지막 커밋 기준입니다.%f"
fi
BUILD_NUMBER="$(git rev-list --count HEAD)"

step "프로젝트 생성 (xcodegen)"
xcodegen generate --quiet

if $run_tests; then
  step "테스트"
  xcodebuild test -project Chaja.xcodeproj -scheme Chaja -destination "platform=macOS,arch=arm64" -derivedDataPath "$ROOT/build/DerivedData" -quiet \
    || fail "테스트 실패"
fi

step "Release 빌드 (빌드 번호 $BUILD_NUMBER)"
rm -rf "$DERIVED/Build/Products/Release"
xcodebuild build -project Chaja.xcodeproj -scheme Chaja -configuration Release -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -quiet \
  || fail "빌드 실패"

step "서명 검증"
codesign --verify --strict --deep "$APP" || fail "서명 검증 실패"
# 서명 요구사항이 인증서에 고정되어 있어야 다시 빌드해도 전체 디스크 접근 권한이 유지된다.
codesign -d -r- "$APP" 2>&1 | grep -q 'certificate leaf = H"' || fail "서명 요구사항에 인증서 고정이 없습니다"
SIGNER="$(codesign -dvv "$APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"
[[ "$SIGNER" == "$IDENTITY" ]] || fail "서명한 인증서가 '$IDENTITY'가 아닙니다: $SIGNER"
lipo -archs "$APP/Contents/MacOS/Chaja" | grep -qx arm64 || fail "arm64 전용 바이너리가 아닙니다"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="$ROOT/build/Chaja-$VERSION.zip"

step "압축 ($ZIP:t)"
rm -f "$ZIP"
# ditto는 확장 속성과 서명을 그대로 보존한다(zip 명령은 서명이 깨질 수 있음).
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 다른 맥에서 받은 충돌 보고서를 코드 줄로 풀려면 배포한 빌드와 같은 dSYM이 필요하다.
DSYM_ARCHIVE="$ROOT/build/dSYMs/Chaja-$VERSION-$BUILD_NUMBER.dSYM"
rm -rf "$DSYM_ARCHIVE"
mkdir -p "$DSYM_ARCHIVE:h"
ditto "$APP.dSYM" "$DSYM_ARCHIVE"

if $install; then
  step "/Applications에 설치"
  # 창을 닫아도 앱이 남아 있으므로 확실히 종료한다.
  osascript -e 'tell application id "com.n22309002.Chaja" to quit' >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x Chaja >/dev/null || break; sleep 0.25; done
  pkill -x Chaja 2>/dev/null || true
  STAGING="$(mktemp -d /tmp/chaja-install.XXXXXX)"
  ditto "$APP" "$STAGING/Chaja.app"
  rm -rf "$INSTALL_PATH"
  mv "$STAGING/Chaja.app" "$INSTALL_PATH"
  rmdir "$STAGING"
  codesign --verify --strict "$INSTALL_PATH" || fail "설치한 앱의 서명 검증 실패"
  open "$INSTALL_PATH"
fi

print -P "%F{green}✔ Chaja $VERSION ($BUILD_NUMBER)%f"
print "  앱: $APP"
print "  zip: $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '), SHA-256 $(shasum -a 256 "$ZIP" | cut -c1-16)…)"
print "  dSYM: $DSYM_ARCHIVE"
$install && print "  설치: $INSTALL_PATH"
exit 0
