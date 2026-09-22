# NexaDrop v0.1.3

Secure local file transfer prototype for Android and Windows.

## GitHub Actions APK build

This repository contains `.github/workflows/build-apk.yml`.

Push the extracted project contents to the root of your GitHub repository. The workflow pins Flutter 3.47.5, Java 17 and Android API 36, then:

1. generates the Android runner,
2. resolves packages,
3. runs `flutter analyze`,
4. runs tests,
5. builds a release APK,
6. uploads `NexaDrop-v0.1.3.apk` as an Actions artifact.

The bootstrap script is invoked with `bash scripts/bootstrap_android.sh`, so Git executable-bit differences on Windows cannot produce exit code 126.

## Output

Open **Actions > Build NexaDrop APK > latest successful run > Artifacts** and download `NexaDrop-Android-APK-v0.1.3`.
