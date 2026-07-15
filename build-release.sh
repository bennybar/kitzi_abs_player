#!/usr/bin/env bash
#
# Builds a signed release of Kitzi and copies the artifact(s) to ~/Downloads.
#
#   ./build-release.sh          # APK only (default)
#   ./build-release.sh --aab    # APK + AAB (the AAB is what Play wants)
#
# Signing uses key.properties + upload-keystore.jks, exactly as the Flutter
# project did. The expected signer is the existing Play upload key.
set -euo pipefail

cd "$(dirname "$0")"

WANT_AAB=false
for arg in "$@"; do
  case "$arg" in
    --aab) WANT_AAB=true ;;
    *) echo "Unknown option: $arg (use --aab for APK + AAB)"; exit 1 ;;
  esac
done

# AGP rejects the system JDK (Java 23 here); use Android Studio's bundled JBR.
if [[ -z "${JAVA_HOME:-}" || ! -x "${JAVA_HOME}/bin/java" ]]; then
  STUDIO_JBR="/Applications/Android Studio.app/Contents/jbr/Contents/Home"
  if [[ -x "$STUDIO_JBR/bin/java" ]]; then
    export JAVA_HOME="$STUDIO_JBR"
  else
    echo "No usable JAVA_HOME and Android Studio JBR not found." >&2
    echo "Set JAVA_HOME to a JDK 17–21 and re-run." >&2
    exit 1
  fi
fi
echo "Using JAVA_HOME=$JAVA_HOME"

DEST="$HOME/Downloads"
mkdir -p "$DEST"

# The version tag makes downloaded files easy to tell apart across builds.
VERSION="$(grep -E 'versionName *=' app/build.gradle.kts | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
CODE="$(grep -E 'versionCode *=' app/build.gradle.kts | head -1 | sed -E 's/[^0-9]//g')"
STAMP="v${VERSION}-${CODE}"

TASKS=(assembleRelease)
$WANT_AAB && TASKS+=(bundleRelease)

echo "Building: ${TASKS[*]}"
./gradlew --no-daemon "${TASKS[@]}"

APK_SRC="app/build/outputs/apk/release/app-release.apk"
APK_OUT="$DEST/kitzi-${STAMP}.apk"
cp "$APK_SRC" "$APK_OUT"
echo "APK -> $APK_OUT"

if $WANT_AAB; then
  AAB_SRC="app/build/outputs/bundle/release/app-release.aab"
  AAB_OUT="$DEST/kitzi-${STAMP}.aab"
  cp "$AAB_SRC" "$AAB_OUT"
  echo "AAB -> $AAB_OUT"
fi

# Confirm the signer is the expected upload key before anyone uploads it.
BT="$(ls -d "$HOME/Library/Android/sdk/build-tools/"*/ 2>/dev/null | sort -V | tail -1)"
EXPECTED="4ed3d9ff3193adafba37b2e13a39d0d3c93e85f018800c6cce87fc991d1daef3"
if [[ -n "$BT" && -x "${BT}apksigner" ]]; then
  ACTUAL="$("${BT}apksigner" verify --print-certs "$APK_SRC" 2>/dev/null \
    | grep -i "SHA-256 digest" | head -1 | awk '{print $NF}')"
  if [[ "$ACTUAL" == "$EXPECTED" ]]; then
    echo "Signer OK: matches the Play upload key."
  else
    echo "WARNING: signer $ACTUAL does not match the expected upload key ($EXPECTED)." >&2
    echo "         Do not upload this build until the keystore is fixed." >&2
  fi
fi

echo "Done."
