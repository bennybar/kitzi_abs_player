#!/usr/bin/env bash
#
# Builds a signed release of Kitzi and copies the artifact(s) to ~/Downloads.
#
#   ./build-release.sh          # APK + AAB (the AAB is what Play wants)
#   ./build-release.sh --no-aab # APK only (skip the Play bundle)
#
# Signing uses key.properties + upload-keystore.jks, exactly as the Flutter
# project did. The expected signer is the existing Play upload key.
set -euo pipefail

cd "$(dirname "$0")"

# The AAB is what Play requires, so it's built every release. --no-aab skips it
# for a quick sideload-only APK.
WANT_AAB=true
for arg in "$@"; do
  case "$arg" in
    --no-aab) WANT_AAB=false ;;
    --aab) WANT_AAB=true ;;  # accepted for compatibility; the AAB now builds by default
    *) echo "Unknown option: $arg (use --no-aab to skip the Play bundle)"; exit 1 ;;
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

# Without key.properties Gradle quietly builds an UNSIGNED app-release-unsigned.apk,
# and the copy below would pick up an older signed APK still in build/outputs,
# stamped with this version. Refuse instead.
if [[ ! -f key.properties ]]; then
  echo "key.properties not found — can't sign a release." >&2
  exit 1
fi

# The version tag makes downloaded files easy to tell apart across builds.
VERSION="$(grep -E 'versionName *=' app/build.gradle.kts | head -1 | sed -E 's/.*"([^"]+)".*/\1/')"
CODE="$(grep -E 'versionCode *=' app/build.gradle.kts | head -1 | sed -E 's/[^0-9]//g')"
STAMP="v${VERSION}-${CODE}"

# Gate the release on the checks BEFORE producing an artifact — assembling first
# meant a release could be cut while unit tests or lint were failing. Set
# SKIP_CHECKS=1 to bypass deliberately (e.g. reproducing an old build).
if [ "${SKIP_CHECKS:-0}" != "1" ]; then
  echo "Running checks: testDebugUnitTest lintDebug"
  ./gradlew --no-daemon testDebugUnitTest lintDebug || {
    echo "Checks failed — refusing to build a release. Re-run with SKIP_CHECKS=1 to override." >&2
    exit 1
  }
fi

TASKS=(assembleRelease)
$WANT_AAB && TASKS+=(bundleRelease)

echo "Building: ${TASKS[*]}"
# Nothing left over from a previous build can be mistaken for this one.
rm -rf app/build/outputs/apk/release app/build/outputs/bundle/release app/build/outputs/mapping/release
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

# The R8 map for THIS build. Without it a crash from the field is an obfuscated
# stack that can't be read once build/ has been overwritten by the next build.
MAP_SRC="app/build/outputs/mapping/release/mapping.txt"
MAP_OUT="$DEST/kitzi-${STAMP}-mapping.txt"
cp "$MAP_SRC" "$MAP_OUT"
echo "Mapping -> $MAP_OUT"

# Confirm the signer is the expected upload key before anyone uploads it.
BT="$(ls -d "$HOME/Library/Android/sdk/build-tools/"*/ 2>/dev/null | sort -V | tail -1)"
EXPECTED="4ed3d9ff3193adafba37b2e13a39d0d3c93e85f018800c6cce87fc991d1daef3"
# Fatal, not a warning: a wrong-key build that exits 0 is one that gets uploaded.
if [[ -z "$BT" || ! -x "${BT}apksigner" ]]; then
  echo "apksigner not found under ~/Library/Android/sdk/build-tools — can't verify the signer." >&2
  exit 1
fi
ACTUAL="$("${BT}apksigner" verify --print-certs "$APK_SRC" 2>/dev/null \
  | grep -i "SHA-256 digest" | head -1 | awk '{print $NF}')"
if [[ "$ACTUAL" == "$EXPECTED" ]]; then
  echo "Signer OK: matches the Play upload key."
else
  echo "Signer $ACTUAL does not match the expected upload key ($EXPECTED)." >&2
  echo "Do not upload this build until the keystore is fixed." >&2
  exit 1
fi

# The AAB is the artifact Play actually receives, and apksigner can't read it, so
# confirm the bundle is signed at all with jarsigner. It shares the APK's signing
# config (checked above), so this is a "did it get signed" sanity check, not a
# second key check.
# jarsigner -verify exits 0 even for an UNSIGNED jar ("jar is unsigned."), so the
# exit code proves nothing; only its "jar verified." line does.
if $WANT_AAB; then
  if "${JAVA_HOME}/bin/jarsigner" -verify "$AAB_SRC" 2>&1 | grep -q "jar verified."; then
    echo "AAB signed OK."
  else
    echo "The AAB is not signed — Play will reject it." >&2
    exit 1
  fi
fi

echo "Done."
