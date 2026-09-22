#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Bootstrap failed at line $LINENO" >&2' ERR

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

for required in lib/main.dart pubspec.yaml analysis_options.yaml platform/android/AndroidManifest.xml; do
  if [[ ! -f "$required" ]]; then
    echo "Missing required project file: $required" >&2
    exit 2
  fi
done

BACKUP="$(mktemp -d)"
trap 'rm -rf "$BACKUP"' EXIT

cp -R lib "$BACKUP/lib"
cp pubspec.yaml "$BACKUP/pubspec.yaml"
cp analysis_options.yaml "$BACKUP/analysis_options.yaml"
if [[ -d test ]]; then
  cp -R test "$BACKUP/test"
fi

echo "[1/4] Generate a clean Android runner with Flutter"
flutter create \
  --overwrite \
  --platforms=android \
  --org com.nexadrop \
  --project-name nexadrop \
  .

echo "[2/4] Restore NexaDrop Dart source"
rm -rf lib test
cp -R "$BACKUP/lib" ./lib
cp "$BACKUP/pubspec.yaml" ./pubspec.yaml
cp "$BACKUP/analysis_options.yaml" ./analysis_options.yaml
if [[ -d "$BACKUP/test" ]]; then
  cp -R "$BACKUP/test" ./test
fi

echo "[3/4] Apply NexaDrop Android manifest"
cp platform/android/AndroidManifest.xml android/app/src/main/AndroidManifest.xml

echo "[4/4] Resolve dependencies"
flutter pub get

echo "Android bootstrap complete."
