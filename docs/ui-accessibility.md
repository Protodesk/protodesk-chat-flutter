# Chat UI accessibility implementation review

Target: WCAG 2.2 AA; native Android and iOS. Reviewed `lib/src/chat_screen.dart`
and the scoped theme/localization APIs on 2026-10-25. This is a source/widget-test
review, not a claim of whole-host-app or physical-device conformance.

## Initial findings and remediation

### 1. Preview image has no accessible name
- File: `lib/src/chat_screen.dart`, `_AttachmentImage`
- WCAG: 1.1.1 Non-text Content (Level A, WCAG 2.0)
- Platforms: Android, iOS
- Severity: MAJOR
- Issue: Full attachment image is not described; redundant thumbnails should be decorative.
- Before:
```dart
Image(image: _provider)
```
- After:
```dart
Image(image: _provider, semanticLabel: widget.semanticLabel,
  excludeFromSemantics: widget.semanticLabel == null)
```

### 2. Async status and errors lack announcement regions
- File: `lib/src/chat_screen.dart`, connection, typing, upload, send, and error text
- WCAG: 4.1.3 Status Messages (Level AA, WCAG 2.1)
- Platforms: Android, iOS
- Severity: MAJOR
- Issue: Text changes are visible but not identified as status changes.
- Before:
```dart
Text(_strings.error(_error!))
```
- After:
```dart
_ChatStatus(_strings.error(_error!))
// Semantics(liveRegion: true), plus a debounced, supported iOS announcement.
```

### 3. Horizontal action groups compete with long text
- File: `lib/src/chat_screen.dart`, message/upload tiles and composer
- WCAG: 1.4.4 Resize Text (Level AA, WCAG 2.0)
- Platforms: Android, iOS
- Severity: MAJOR
- Issue: Trailing rows and inline composer buttons leave too little space for scaled text/translations.
- Before:
```dart
ListTile(trailing: Row(mainAxisSize: MainAxisSize.min, children: actions))
Row(children: [Expanded(child: input), send])
```
- After:
```dart
Column(crossAxisAlignment: CrossAxisAlignment.start,
  children: [content, Wrap(children: actions)])
// Composer uses a stacked input/actions layout on narrow or enlarged-text views.
```

### 4. Host density can shrink SDK controls
- File: `lib/src/chat_screen.dart`, scoped Material controls
- WCAG: 2.5.8 Target Size (Minimum) (Level AA, WCAG 2.2)
- Platforms: Android, iOS
- Severity: MINOR
- Issue: Dense host themes can reduce interaction geometry; retain host colors/type while protecting SDK targets.
- Before:
```dart
Theme(data: widget.theme ?? Theme.of(context), child: chat)
```
- After:
```dart
Theme(data: ChatTheme.accessible(widget.theme ?? Theme.of(context)), child: chat)
// Padded, standard-density controls with minimum 48 x 48 logical-pixel targets.
```

### 5. Preview transition ignores reduced-motion preference
- File: `lib/src/chat_screen.dart`, `_preview`
- WCAG: 2.3.3 Animation from Interactions (Level AAA, WCAG 2.1)
- Platforms: Android, iOS
- Severity: MINOR
- Scope: Additional strategy requirement (reduced motion), not an AA failure.
- Before:
```dart
DialogRoute<void>(context: context, builder: builder)
```
- After:
```dart
DialogRoute<void>(context: context, builder: builder,
  animationStyle: MediaQuery.disableAnimationsOf(context)
    ? AnimationStyle.noAnimation : null)
```

## Existing behavior retained

Material buttons/text fields supply keyboard focus, roles, activation and
selection/paste. No drag-only or long-press-only action is introduced. The chat
composer collects free text, not structured personal information; authentication
and permission prompts remain host-owned. Status uses text rather than color
alone. SafeArea and Scaffold keyboard resizing remain enabled. Host theme and
locale changes preserve current conversation and unsent draft.

## Acceptance boundaries

Run VoiceOver, TalkBack, Switch Control/Switch Access, external-keyboard traversal,
real keyboard/rotation and maximum system font settings on physical devices.
Verify the complete host navigation and custom attachment viewer. Validate host
font/color overrides and foreground/background announcement behavior. Flutter
widget guidelines and contrast-role checks do not certify all custom themes.
No claim is made for web/desktop or translated customer/server-authored content.

References:
- [Flutter accessibility testing](https://docs.flutter.dev/ui/accessibility/accessibility-testing)
- [Flutter announcement API](https://api.flutter.dev/flutter/semantics/SemanticsService/sendAnnouncement.html)

## Local verification (2026-10-25)

Automated coverage includes English/Indonesian fallback and overrides, runtime
locale/theme changes preserving drafts, named attachment previews, closed-loop
dialog focus, reduced-motion transitions, status announcement debounce/disposal,
keyboard activation, native tap-target/labeled-target guidelines, and contrast.
Layout tests exercise 320-pixel portrait and 740-pixel landscape viewports at
1x/2x/3x text scale, including the portrait keyboard inset. Existing automatic
read-reporting tests pass with ancestor clipping respected.

A batched rendered review covered English light phone, Indonesian dark enlarged
phone, Indonesian light tablet, and Indonesian dark enlarged landscape layouts.
Short viewports scroll to the composer; long history remains separately scrollable.
These local checks do not replace the physical-device acceptance above.
