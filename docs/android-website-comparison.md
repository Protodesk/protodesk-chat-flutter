# Android and website chat comparison

Captured on November 3, 2026 on a Pixel 7a emulator (API 37, Chrome 156).
Each image shows the deployed chat widget on [protodesk.io](https://protodesk.io/) on the left
and the native Flutter messenger on the right. Both used the same device, English and default text size. The chat captures use
a 411 × 789 logical content viewport and the light theme except for the dark pair.
The keyboard comparison uses the full device screen, including Chrome's toolbar,
the host app's status bar and Gboard. Both full-device images are reduced to the
same width. The other captures show only chat content. Chrome rounded that viewport
to 788 pixels tall. The images live in the SDK repository.

| Screen | Side by side |
| --- | --- |
| New chat and composer | [Chat](livechat-reference/android/chat.png) |
| Empty conversation history | [Messages](livechat-reference/android/messages.png) |
| Home and featured articles | [Home](livechat-reference/android/home.png) |
| Help search and topics | [Help Center](livechat-reference/android/help.png) |
| Getting started | [Collection](livechat-reference/android/collection.png) |
| Navigate your Protodesk workspace | [Article](livechat-reference/android/article.png) |
| Four-message conversation | [Populated chat](livechat-reference/android/populated.png) |
| Received PDF | [Attachment](livechat-reference/android/attachment.png) |
| Text file ready to send | [Staged file](livechat-reference/android/staged.png) |
| Composer with Gboard open | [Open keyboard](livechat-reference/android/keyboard.png) |
| Dark conversation with a PDF | [Dark mode](livechat-reference/android/dark.png) |

Chrome reported Roboto for the greeting inside the embedded widget, despite Inter
being the first family in its CSS. Flutter uses the system Roboto on Android by
default. A host's explicit font override still applies. Text rasterization,
ellipsis placement and scroll indicators can differ between Chrome and Flutter;
the screenshot pairs record the observed result at this viewport.

For the conversation comparisons, local fixtures supplied identical messages,
timestamps, connection state and attachment metadata. Chrome ran the deployed
widget and its own dark CSS. The staged file was a synthetic three-byte text file,
and the binary transfer and completion responses were intercepted locally. Both
clients exercised their actual attachment UI.

When Gboard opens, Chrome pans the page to the focused textarea. The native app
resizes around the keyboard and keeps its header and complete composer accessible.
Gboard shows a Return symbol in Chrome and a Send symbol in Flutter. Tapping the
action submits the draft in both.

To repeat the native comparison from the SDK checkout, run `flutter pub get`
in the SDK and example first. Start a Pixel 7a emulator with the on-screen keyboard enabled and make `adb` available on PATH or set `ANDROID_HOME`. Then run:

```sh
python3 tool/capture_android_comparison.py /tmp/chat-screens --device emulator-5554
```

The test injects public Help content, the logo and the synthetic threads from
`test/support/android_website_content.json`. It checks draft restoration, article
expansion, the return path to the topic, and a keyboard submission to the local
fixture. It also checks the staged file can be removed. Refresh the public fixture
when the website branding or Help content changes.

To repeat the five conversation captures in Android Chrome, open the website on
a disposable Pixel emulator with Gboard enabled and dismiss Chrome’s first-run
dialogs. With Node.js, npm and adb on PATH,
run these commands from the SDK checkout:

```sh
adb -s emulator-5554 forward tcp:19273 localabstract:chrome_devtools_remote
npm install --prefix build/browser-tools playwright@1.59.1
NODE_PATH=./build/browser-tools/node_modules node tool/capture_android_website.cjs /tmp/chat-screens emulator-5554
adb -s emulator-5554 forward --remove tcp:19273
```
