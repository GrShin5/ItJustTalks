# Contributing to ItJustTalks

Thanks for your interest in ItJustTalks. This document covers how to build
the project, run its checks, and prepare a pull request.

## Prerequisites

- macOS 27. The on-device AI uses Foundation Models APIs introduced in macOS 27
  (`SystemLanguageModel.variant`, `LanguageModelSession.Usage`,
  `LanguageModelError`, `SystemLanguageModel.Error.assetsUnavailable`), so
  `Package.swift` (`.macOS(.v27)`), the app's Info.plist and the preflight check
  all require macOS 27.
- Swift 6.4 or later (the manifest uses tools version 6.4) with the macOS 27 SDK.
- Apple Silicon, Apple Intelligence enabled, and on-device models ready
  for end-to-end AI checks. Verified on Apple M5 Max (64GB memory). M1 (8GB) is planned.
  Core 3 Macs are unverified.
- Git and OpenSSL 3 for initial signing certificate creation.

## Building

```bash
swift build
bash scripts/make_app.sh debug
```

The app bundle is `dist/ItJustTalks.app`. Use `release` instead of `debug`
for distribution. A stable local signing certificate is required; read
[Appendix B](docs/manual/en.md#appendix-b) before running
`scripts/make_signing_cert.sh`. Reuse the same identity for updates.

## Running the checks

```bash
swift build
swift test
.build/debug/ItJustTalks --test-regressions
bash scripts/check_identifiers.sh
bash scripts/dev/check_privacy.sh
bash scripts/dev/test_check_privacy.sh
```

The regression suite does not require external AI or network access.
Pasteboard fixtures may self-skip when a pasteboard server is unavailable;
report skips separately from passes. Real microphone, permissions, hotkey,
and insertion checks still need a person using the app. Use synthetic data
for model evaluation and testing; never submit real speech, mail, clipboard,
dictionary, or custom instruction contents in logs or reports.

## Continuous integration

This repository has no CI. Include the local checks you actually ran and
their results in each PR, including skipped checks and the reason.

## Code style

- Follow the surrounding style. Keep new code comments in Japanese unless
  the surrounding file is already in English. Use English imperative
  commit subjects, such as `fix: correct hands-free trigger timeout`.
- Keep changes focused; avoid unrelated formatting, renaming, or refactoring.
- Add focused logic coverage in `Tests/ItJustTalksAITests/`,
  `Tests/ItJustTalksAppTests/`, or
  `Sources/ItJustTalks/Support/RegressionTestSuite.swift` as appropriate.
- Preserve the on-device-only architecture using `SystemLanguageModel`.
  Do not add cloud AI, networking, a generic model path, or PCC entitlements
  to product code. Never log user text.

## Pull requests

- Explain the problem, resulting behavior, and relevant validation.
- Call out changes affecting permissions, text insertion, clipboard,
  AI validation, or automatic sending.
- Keep one change per PR. Run appropriate local checks; distinguish test
  success from device and model-quality acceptance.
- For human-operated checks, mark the PR `needs-device-test` and leave it
  unmerged until a maintainer confirms the device checks.
- For UI changes, mention Japanese source strings and English translations
  in `Sources/ItJustTalks/Resources/en.lproj/Localizable.strings`.
- For larger changes, discussing the approach in an issue first is welcome.

## Licensing of contributions

ItJustTalks is derived from Koedex and licensed under the Apache License
2.0; see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Unless you state otherwise in writing, contributions intentionally
submitted for inclusion in ItJustTalks are under the same Apache License
2.0, without additional terms. This follows Section 5's inbound=outbound
rule; submitting a pull request is taken as agreement to it.

Only submit work you have the right to license this way. Do not paste
incompatibly licensed code. Identify third-party sources in the PR so
attribution and NOTICE requirements can be handled before merging.
