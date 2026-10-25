# Release candidate checks

The SDK remains an unpublished preview (`publish_to: none`). No command or workflow
in this repository publishes a package. The SDK is licensed under Apache-2.0. Staged candidates include LICENSE and
NOTICE, and the native podspec references the same license. This applies only
to the Flutter SDK repository.

## Local validation

Use Flutter 3.47.5 / Dart 3.13.4, then run from the SDK checkout:

```sh
bash tool/check_release.sh
```

This runs analysis and tests for the SDK, example, and optional push adapters;
staging safety tests; API documentation with link validation; and a pub.dev dry
run in a temporary directory. It needs dependency network access, but no publishing
credentials. Missing licensing or pub validation errors fail the gate. Do not
force publication or refresh golden baselines merely to make this gate pass.
Generated API documentation is in `doc/api/` and is ignored by Git.

To inspect a candidate independently, choose a new directory outside the checkout:

```sh
python3 tool/stage_release.py /tmp/protodesk-chat-candidate
cd /tmp/protodesk-chat-candidate
flutter pub get
flutter pub publish --dry-run
```

Staging preserves the source publication block and removes it only in the copy.
It copies allowlisted source types, rejects linked inputs, and excludes local
build output and credential file types. Review the printed manifest and package
contents before any eventual publication; allowlisting cannot detect secrets
embedded in ordinary source code. Repository `docs/` becomes `doc/guides/`, and
`examples/push_adapters/` becomes `example/push_adapters/`. The package includes
example Dart sources; use the repository checkout for complete runnable native
hosts and integration tests.

## CI and candidate artifacts

`.github/workflows/release-checks.yml` uses the same pinned Flutter version on
macOS and runs the local gate for pull requests, main, version tags, and manual
runs. Tags must equal `v` plus the pubspec version, including prerelease suffixes.
Successful manual/tag runs produce a candidate archive, manifest, SHA-256 digest,
and source commit identifier. Validation logs and generated API documentation are
retained for 14 days. This workflow has not yet been exercised on a remote: the
SDK checkout has no configured Git remote. It has read-only repository permissions
and no publishing credentials or publication step.

## Support and remaining release gates

The declared minimum toolchain is Flutter 3.47.5 / Dart 3.13.4, matching local
validation. Supported platforms are Android and iOS; native metadata declares
Android API 23 and iOS 13.0 minimums. Those declarations are not physical-device
acceptance evidence. See `testing.md` for exact tested boundaries, golden baseline
requirements, and physical device checks. iOS secure-storage simulator acceptance
passed; protected-file acceptance still requires physical devices. Native Swift
Package Manager migration remains separate from the current CocoaPods integration.

Before first publication:

- Preserve LICENSE and NOTICE in release candidates and align native metadata.
- Obtain a clean candidate dry run and inspect its contents.
- Configure the repository URL and run CI remotely.
- Verify pub.dev publisher access and package-name ownership/availability.
- Complete required physical Android/iOS acceptance and review the changelog.
- Explicitly authorize publication of a specific reviewed version and commit.

Automatic publishing can later use pub.dev trusted publishing/OIDC instead of a
long-lived token. It is intentionally not configured by this candidate workflow.

## Latest local packaging validation

On 2026-10-25, the Apache-2.0 candidate passed `flutter pub publish --dry-run`
with zero warnings (111 KB compressed archive after presentation/lifecycle changes). LICENSE and NOTICE were checked
against their source copies. Three staging safety tests passed. This is local
package validation, not confirmation of publisher ownership or remote CI success.
