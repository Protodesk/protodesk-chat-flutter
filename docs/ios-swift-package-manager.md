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
otherwise. The example app enables SwiftPM in its `pubspec.yaml`.
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

The example project therefore omits that override; Flutter does not add it back
on later builds. Edit the plugin's Swift source from `ios/` directly rather than
through the example's Xcode project. Apps that depend on the SDK are not
affected: they have no override, so any checkout or cache folder name works.

## Verification (2026-10-25, Flutter 3.47.5, iPhone 17 Pro / iOS 26.5 simulator)

- Example app, SwiftPM: builds; `PrivacyInfo.xcprivacy` is in the app bundle;
  `integration_test/chat_native_test.dart` passes.
- Example app, CocoaPods: builds; `chat_native_test.dart` passes.
- New consumer app, CocoaPods: builds with the `protodesk_chat` pod and its
  privacy bundle.
- New consumer app, SwiftPM, depending on a checkout named
  `protodesk-chat-flutter`: builds with the privacy bundle.

Not yet verified: physical devices, archive/App Store validation of the privacy
report, and `pod lib lint` (the podspec is path-sourced and unpublished).
