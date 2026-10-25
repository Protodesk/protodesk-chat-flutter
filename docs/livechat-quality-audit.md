# Livechat messenger quality audit (phase 7)

Date: 2026-10-25. Scope: `ChatMessenger` Home, Messages, conversation, Help
home, Help article and conversation setup. Method: impeccable's native audit
(`audit.native.md`) against its iOS and Android references, run as executable
checks where possible (`test/src/messenger_quality_test.dart`), plus review of
every golden in `test/goldens/`. **Nothing here was verified on a physical
device, simulator or emulator.**

## Audit health score

| # | Dimension | Score | Key finding |
|---|-----------|-------|-------------|
| 1 | Accessibility | 3 | Guideline checks pass in every view and theme; real VoiceOver/TalkBack sessions not yet run |
| 2 | Performance | 3 | Conversation, message and Help lists are lazy; Help articles render eagerly (needed for "On this page" anchors) |
| 3 | Appearance & theming | 3 | Material colour roles throughout; the connection dot uses one fixed green |
| 4 | Platform conformance | 3 | Material 3 on both platforms with system Back, adaptive back icon and safe areas; no Cupertino-specific controls on iOS |
| 5 | Adaptivity | 3 | Phone bar / tablet rail, 720 px content column, landscape and 3× text pass; foldables and multi-window untested |
| **Total** | | **15/20** | **Good** |

**Platform conformance verdict: pass.** It reads as a native Material app, not
a ported web page: Material navigation (bar, then rail at ≥ 840 px), Material
dialogs and menus, system Back and edge-swipe preserved, no hover affordances.
On iOS it remains Material-styled by design (the SDK's existing choice); safe
areas, Dynamic Type and Reduce Motion are honoured.

## Executable checks (37, all passing)

- 6 views × light/dark: Android 48 dp and iOS 44 pt tap targets, labelled tap
  targets, and text contrast (`meetsGuideline`).
- 6 views at 2× (320×640), 3× (320×740) and landscape 2× (740×320) in
  Indonesian, plus right-to-left: no layout overflow or exceptions.
- Bottom navigation on phones, navigation rail on wide layouts.

## Findings fixed in this pass

| Severity | Issue | Fix |
|---|---|---|
| P1 | Help language menu (44 px) and "View all articles" (40 px) under the 48 px touch minimum | Minimum 48 px targets; removed compact density |
| P1 | Help home overflowed at 2×/3× text: heading and "View all articles" forced onto one line | Heading and button wrap |
| P1 | Help code blocks overflowed at 2×/3×: label and "Copy code" button on one line | Wrapping header; icon button with tooltip and a live "Copied" status |
| P1 | Conversation overflowed by 368 px at 3× on 320×740: compact layout only started below 650 px | Compact (scrolling) layout below 900 px at large text, for conversations only |
| P1 | Help article at 3× squeezed into the conversation's fixed 240 px pane | Only conversations use the compact pane; other sections scroll themselves |
| P2 | Compact conversation pane fixed at 240 px left a third of the screen empty | Pane uses 60% of the height (minimum 240 px) |
| P2 | Header titles could grow without bound at large text | Two lines, then ellipsis |
| P2 | A phone-style bottom bar stretched across tablets | Navigation rail at ≥ 840 px, from the messenger's own width (works in split view) |

Earlier phases fixed two P0s found the same way: Home's overlapping card
ignoring taps on its upper edge (phase 5) and Help discarding a directly opened
article on first load (phase 6).

## Remaining

- **P1 — device acceptance.** Run VoiceOver and TalkBack through every view,
  check focus order after navigation, and confirm Dynamic Type/font scale,
  Reduce Motion, edge-swipe and predictive Back on hardware (see the
  strategy's Flutter checklist).
- **P2 — Home card shadow.** In goldens the soft shadow under Home's contact card
  renders as a flat band; confirm the blur on a device and tune it if it looks
  the same.
- **P2 — font weights in goldens.** The golden harness loads only regular
  Roboto, so bold text there looks medium. Real devices use the platform weights.
- **P3 — fixed status colour.** The "Connected" dot is a fixed green; consider a
  theme extension if hosts need to brand it.
- **P3 — right-to-left chrome.** RTL layout is overflow-free, but the SDK ships
  only English and Indonesian chrome; RTL languages need translations first.

## Positive findings

- Every interactive element has a label; status text uses live regions with
  debounced iOS announcements.
- Reduced motion disables the greeting typing, list transitions and article
  scrolling animations.
- Colours come from `ColorScheme` roles, so host themes and Chat App brands stay
  legible in light and dark.
- Configuration, Help and conversation state are dropped on identity changes;
  stale responses cannot repaint another account's data.
