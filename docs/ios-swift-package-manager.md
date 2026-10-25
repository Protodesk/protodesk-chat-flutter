# iOS: Swift Package Manager and CocoaPods

The iOS plugin (protected attachment storage) builds with either Swift Package
Manager (SwiftPM) or CocoaPods from one source tree:

```
ios/
  protodesk_chat.podspec            CocoaPods; points at the sources below
  protodesk_chat/
    Package.swift                   SwiftPM; iOS 13+, depends on FlutterFramework
    Sources/protodesk_chat/
      ProtodeskChatPlugin.swift
      PrivacyInfo.xcprivacy
```

Host apps need no SDK-specific setup. Flutter picks SwiftPM when it is enabled
(`flutter config --enable-swift-package-manager`, or per app in `pubspec.yaml`
under `flutter: config: enable-swift-package-manager: true`) and CocoaPods
otherwise. The example app enables SwiftPM in its `pubspec.yaml`, and its
committed `Podfile.lock` and Xcode project reflect that SwiftPM build.
`flutter_secure_storage` also ships SwiftPM support, so an all-SwiftPM build
leaves only Flutter itself in CocoaPods.

## Privacy manifest

`PrivacyInfo.xcprivacy` declares no tracking and no collected data. It declares
`NSPrivacyAccessedAPICategoryFileTimestamp` with reason `C617.1` because the
plugin calls `FileManager.attributesOfItem(atPath:)` to check the size and
protection class of its own attachment files inside the app container. SwiftPM
bundles it as `protodesk_chat_protodesk_chat.bundle`; CocoaPods as
`protodesk_chat_privacy.bundle`. Update the manifest if the plugin starts using
another required-reason API.

## Example app: no local package override

Flutter's SwiftPM migration adds the plugin being developed to its example
app's Xcode project as a local package override (`../../ios/protodesk_chat`).
SwiftPM names that override after its folder (`protodesk_chat`) but names the
dependency after the plugin's checkout folder. When the checkout folder is not
named `protodesk_chat` (for example `protodesk-chat-flutter`), Xcode fails with
"unable to override package 'protodesk_chat' because its identity ... doesn't
match override's identity". With SwiftPM disabled, the same reference makes
Xcode look for `ios/FlutterFramework`, which only SwiftPM builds generate.

The example project therefore omits that override. With Flutter 3.47.5,
repeated builds did not add it back, but a later Flutter version or a re-run of
the migration may. `tool/check_ios_packaging.sh` fails if the override returns;
delete the `protodesk_chat` file reference (`path = ../../ios/protodesk_chat`)
from `example/ios/Runner.xcodeproj/project.pbxproj` again. Checking the SDK out
into a folder named `protodesk_chat` also avoids the conflict. Edit the
plugin's Swift source from `ios/` directly rather than through the example's
Xcode project. Apps that depend on the SDK are not affected: they have no
override, so any checkout or cache folder name works.

## Checking both package managers

Run `bash tool/check_ios_packaging.sh` (macOS with Xcode; `tool/check_release.sh`
runs it automatically there). It builds a throwaway host app with SwiftPM and
with CocoaPods, then the example with SwiftPM, and checks that the plugin's
privacy manifest ships in each app and that each app resolved the plugin
through the expected package manager.

Use that script, not the example app, to test CocoaPods. Turning SwiftPM off in
the example makes `pod install` add the `protodesk_chat` pod and a
"[CP] Embed Pods Frameworks" build phase, rewriting the tracked `Podfile.lock`
and `project.pbxproj`. If you do try it, restore both files afterwards with
`git restore example/ios/Podfile.lock example/ios/Runner.xcodeproj/project.pbxproj`.

## Verification (2026-10-25, Flutter 3.47.5, iPhone 17 Pro / iOS 26.5 simulator)

- Example app, SwiftPM: builds; `PrivacyInfo.xcprivacy` is in the app bundle;
  `integration_test/chat_native_test.dart` passes.
- Example app, CocoaPods: builds; `chat_native_test.dart` passes.
- New consumer app, CocoaPods: builds with the `protodesk_chat` pod and its
  privacy bundle.
- New consumer app, SwiftPM, depending on a checkout named
  `protodesk-chat-flutter`: builds with the privacy bundle.
- `tool/check_ios_packaging.sh`: passes locally (about 1.5 minutes).

Not yet verified: physical devices, archive/App Store validation of the privacy
report, and `pod lib lint` (the podspec is path-sourced and unpublished).
