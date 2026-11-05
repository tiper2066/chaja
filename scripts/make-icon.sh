#!/bin/zsh
# ref-assets/chaja_icon.png → Chaja/Resources/Assets.xcassets/AppIcon.appiconset
# 원본은 1600px 투명 캔버스 중앙(약 760px)에 아이콘 본체가 있다.
# macOS 아이콘 그리드(1024 캔버스에 824 본체)에 맞추려면 본체 폭 × 1024/824 크기의 정사각형으로 잘라야 한다.
set -euo pipefail

ROOT="${0:A:h:h}"
SRC="$ROOT/ref-assets/chaja_icon.png"
OUT="$ROOT/Chaja/Resources/Assets.xcassets/AppIcon.appiconset"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

CROP_SIZE=944
CROP_Y=335
CROP_X=327

mkdir -p "$OUT"
sips -c "$CROP_SIZE" "$CROP_SIZE" --cropOffset "$CROP_Y" "$CROP_X" "$SRC" --out "$TMP/master.png" >/dev/null
sips -z 1024 1024 "$TMP/master.png" --out "$TMP/master.png" >/dev/null

for size in 16 32 64 128 256 512 1024; do
  sips -z "$size" "$size" "$TMP/master.png" --out "$OUT/icon_${size}.png" >/dev/null
done

cat > "$OUT/Contents.json" <<'JSON'
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_64.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_1024.png" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

echo "AppIcon 생성 완료: $OUT"
