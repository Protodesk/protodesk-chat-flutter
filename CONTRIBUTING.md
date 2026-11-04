# Contributing to Protodesk Chat for Flutter

Use the Flutter version pinned in CI (currently 3.47.5). The public client and
widget libraries live in `lib/`. The runnable Android and iOS host is in
`example/`, and optional notification adapters live in `examples/push_adapters/`.
Maintainers use `tool/` to run release checks, stage the pub.dev package, and
capture screenshots. The published package excludes these scripts.

## Check a change

```sh
flutter pub get
flutter analyze
flutter test --exclude-tags golden
```

On macOS, run `flutter test` to include the screenshot baselines. For changes to
a host or push adapter, run analysis and tests from that example’s directory too.
See the [testing guide](docs/testing.md) for native integration tests and the
procedure for reviewing intentional golden changes.

## Update the screenshots

The four PNGs in `screenshots/` are native Android captures used by the README
and the pub.dev listing. They use public Help content and synthetic conversations.
With the example dependencies installed and the Pixel emulator running, capture
them from the SDK root (substitute your device ID).

```sh
python3 tool/capture_android_comparison.py build/android-audit --device emulator-5554
cp build/android-audit/android-home.png screenshots/home.png
cp build/android-audit/android-populated.png screenshots/conversation.png
cp build/android-audit/android-help.png screenshots/help.png
cp build/android-audit/android-dark.png screenshots/dark-conversation.png
```

Use absolute HTTPS image URLs in the README so pub.dev can display the gallery.
When you replace a capture, point its URL at the Git revision containing the new PNG.
Review the four images at phone size. Update the descriptions in `pubspec.yaml`
and README alt text if the scenes change. The separate [Android comparison](docs/android-website-comparison.md)
records the native and website views side by side.

Older published READMEs still load the SVGs in `docs/diagrams/` from the main
branch. Keep those filenames available when updating the gallery.

## Prepare a release

Run `bash tool/check_release.sh` for the full validation and pub.dev dry run.
The [release guide](docs/releasing.md) describes the staged package and CI
artifacts. Record user-visible changes in the changelog before tagging a release.
