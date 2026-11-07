# Security Policy

## Reporting a vulnerability

Please do not open a public issue for security vulnerabilities.

Report vulnerabilities through GitHub's private security advisory feature
on this repository: open the **Security** tab, then **Advisories** →
**Report a vulnerability**. This creates a private channel between you and
the maintainer, separate from the public issue tracker.

If you cannot use that channel for any reason, open a public issue containing
**only** the sentence "I would like to report a security issue" and nothing
else — no details, no reproduction steps, no payload. The maintainer will reply
with a private channel. There is no security email address for this project.

Include as much detail as you can:

- The version or commit you tested (`git rev-parse HEAD`, or the app's
  build git SHA, which is embedded in `Info.plist` as `ItJustTalksBuildGitSHA`).
- Steps to reproduce, and the impact you believe the issue has.
- Whether the issue requires local access, a malicious clipboard/selection
  payload, an instruction embedded in target text, or something else.

## Supported versions

This documentation targets ItJustTalks 0.1.1. There is no formal support
matrix; only the latest published release is supported. When a release tag
is available, reproduce against a fresh build from that tag, obtained and
verified as described in the README, before reporting.

## Response window

This is a project maintained in spare time. Please allow up to 7 days for
an initial response acknowledging the report, and up to 30 days for a fix
or a mitigation plan, depending on severity. If you have not heard back
within that window, it is fine to follow up on the same advisory thread.

## Scope

ItJustTalks processes speech and AI requests on this Mac, using only Apple
Foundation Models on-device for AI. It does not use Codex, ChatGPT, OpenAI,
external AI, or web search. The OS may download speech and AI model assets.
The target mail or chat app can send inserted text through its own network
activity. Vulnerabilities in Apple's frameworks belong upstream; issues in
this app's permission handling, text insertion, clipboard handling, prompt
construction, validation, and local storage belong in this repository.

## Known limitations

ItJustTalks is an early release. These limitations are relevant when
assessing a report. A concrete attack path, reproduction, or behavior beyond
the documented limits is welcome; please use the private reporting channel.

- **Secret-looking fields are not necessarily secure fields.** Secure Input
  and accessibility checks depend on the information supplied by macOS and
  the target app. Avoid using sensitive text as test data.
- **AI validation is incomplete.** On-device processing does not guarantee
  factual accuracy, complete meaning preservation, or perfect resistance to
  instructions embedded in target text. Generated results needing review
  must not be automatically applied or sent.
- **Clipboard transports have platform limits.** Clipboard ownership checks
  protect newer copies, but a failed transaction may report that prior
  clipboard contents could not be restored. Other clipboard tools and
  Universal Clipboard follow their own behavior and settings.
- **History is enabled by default.** Retention is 180 days per mode; users
  can disable saving and delete existing entries in the History tab. AI
  Command and clipboard history save the spoken instruction, not the target
  text or generated answer. Backups and exports have separate retention.
- **Insertion and sending depend on the target app.** Uncertain insertion
  does not trigger automatic repasting or resending. Some compatibility
  paths cannot verify every inserted character and require additional
  consent for external automatic sending. See the manual’s
  [limitations](docs/manual/en.md#chapter-3) and
  [privacy chapter](docs/manual/en.md#chapter-12).
