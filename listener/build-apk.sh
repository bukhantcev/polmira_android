#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SDK_DIR="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"
BUILD_TOOLS="${BUILD_TOOLS:-$SDK_DIR/build-tools/34.0.0}"
PLATFORM_JAR="${PLATFORM_JAR:-$SDK_DIR/platforms/android-34/android.jar}"

AAPT2="$BUILD_TOOLS/aapt2"
D8="$BUILD_TOOLS/d8"
APKSIGNER="$BUILD_TOOLS/apksigner"
ZIPALIGN="$BUILD_TOOLS/zipalign"

APP_ID="ru.polmira.listener"
OUT_DIR="$ROOT_DIR/build"
GEN_DIR="$OUT_DIR/gen"
CLS_DIR="$OUT_DIR/classes"
DEX_DIR="$OUT_DIR/dex"
KEYSTORE="$OUT_DIR/polmira-listener-debug.keystore"
UNSIGNED_APK="$OUT_DIR/polmira-listener-unsigned.apk"
UNALIGNED_APK="$OUT_DIR/polmira-listener-unaligned.apk"
APK="$OUT_DIR/polmira-listener.apk"

for tool in "$AAPT2" "$D8" "$APKSIGNER" "$ZIPALIGN"; do
  if [[ ! -x "$tool" ]]; then
    echo "Не найден инструмент: $tool" >&2
    exit 1
  fi
done

if [[ ! -f "$PLATFORM_JAR" ]]; then
  echo "Не найден android.jar: $PLATFORM_JAR" >&2
  exit 1
fi

rm -rf "$OUT_DIR"
mkdir -p "$GEN_DIR" "$CLS_DIR" "$DEX_DIR" "$OUT_DIR/compiled"

"$AAPT2" compile --dir "$ROOT_DIR/src/main/res" -o "$OUT_DIR/compiled"
"$AAPT2" link \
  -I "$PLATFORM_JAR" \
  --manifest "$ROOT_DIR/AndroidManifest.xml" \
  --java "$GEN_DIR" \
  --min-sdk-version 23 \
  --target-sdk-version 34 \
  --auto-add-overlay \
  -o "$UNSIGNED_APK" \
  "$OUT_DIR"/compiled/*.flat

javac \
  -source 8 \
  -target 8 \
  -encoding UTF-8 \
  -classpath "$PLATFORM_JAR:$GEN_DIR" \
  -d "$CLS_DIR" \
  $(find "$ROOT_DIR/src/main/java" "$GEN_DIR" -name '*.java' | sort)

"$D8" \
  --min-api 23 \
  --classpath "$PLATFORM_JAR" \
  --output "$DEX_DIR" \
  $(find "$CLS_DIR" -name '*.class' | sort)

cp "$UNSIGNED_APK" "$UNALIGNED_APK"
(cd "$DEX_DIR" && zip -q -r "$UNALIGNED_APK" classes.dex)

"$ZIPALIGN" -f -p 4 "$UNALIGNED_APK" "$OUT_DIR/polmira-listener-aligned.apk"

keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -storepass android \
  -keypass android \
  -alias androiddebugkey \
  -keyalg RSA \
  -keysize 2048 \
  -validity 10000 \
  -dname "CN=Polmira Listener Debug,O=Polmira,C=RU" >/dev/null 2>&1

"$APKSIGNER" sign \
  --ks "$KEYSTORE" \
  --ks-pass pass:android \
  --key-pass pass:android \
  --out "$APK" \
  "$OUT_DIR/polmira-listener-aligned.apk"

"$APKSIGNER" verify "$APK"
echo "$APK"
