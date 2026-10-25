# Messenger UI refinement — 2026-10-25

This pass preserves the existing Home / Messages / Help information architecture,
cyan brand, zinc neutrals, headless APIs and host-owned navigation. It refines the
existing product rather than replacing the locally updated messenger.

## Changes

- Home has a stronger heading hierarchy; shared navigation shows the selected
  destination with a restrained brand tint on phones and tablets.
- Messages puts Start a conversation before the history list, so older pages do
  not bury the action. Unread conversations use a tint and stronger title weight.
- The composer has a clear primary send control, a stable focus outline, and a
  busy indicator. Empty/whitespace-only drafts cannot be sent; ready attachments
  still permit an attachment-only send. Offline text queuing remains available.
- Optional contact collection starts compact. Add email expands the existing
  form and focuses its input. Closing it keeps the local draft and does not save
  or dismiss on the server. Existing save/dismiss retries and identity isolation
  remain in place.
- Home and Help search show a leading search icon and a localized Clear search
  control when populated; clearing Help returns to topic browsing.
- Setup and shared fields have rounded outlined boundaries and clear focus/error
  states. Existing validation and keyboard/autofill behavior remain intact.
- Golden fixtures load regular, medium and bold Roboto from the pinned SDK so
  screenshot review includes the intended typographic hierarchy.

## Verification boundaries

Review covers twelve golden variants, light/dark themes, phone/tablet layouts,
English/Indonesian, and enlarged text. The existing executable quality matrix
checks tap targets, labels, contrast, RTL and overflow up to 3× text, along with
interaction tests for contact, setup, search and offline sending. This is local
widget/golden evidence, not physical VoiceOver/TalkBack or device acceptance.
No new runtime dependency, environment variable, backend contract or publication
step is introduced.
