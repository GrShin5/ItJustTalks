# ItJustTalks update prompt

Paste the entire code block below into an AI coding agent. The agent checks the target version and shows it with the current version. You do not need to attach any personal data. The agent's own network use is separate from the app's local AI processing.

The [Japanese version](agent-update-prompt.md) has the same content.

```text
Update ItJustTalks on this Mac from source, keeping the same signature.
Source: https://github.com/GrShin5/ItJustTalks

Rules:
- Work only on ItJustTalks. AI processing uses only the on-device model in Apple Foundation Models. Do not install external AI tools, sign in to them, or set up API keys.
- Never upload user data. Do not read, print, or send the contents of speech, mail, selected text, the clipboard, the dictionary, history, or settings. Do not upload diagnostic information, and leave sensitive values out of your reports. Limit network use to fetching the specified source and required development dependencies.
- Do not change security settings. Do not weaken Gatekeeper, SIP, the privacy permission database, or Keychain protection, and do not disable verification, use ad-hoc signing, or reset all permissions. Leave macOS authentication and permission prompts to the user.
- If a new signing certificate is needed, explain that it will be registered in the login keychain and needs a code-signing trust setting, and always get the user's approval before doing it. Stop if the user does not want that. This approval does not permit any other security setting change.
- Do not touch Koedex's app, repository, or data. Reading, writing, migrating, deleting, or changing permissions of `~/Library/Application Support/Koedex*` is prohibited.
- If you find modified sources or conflicts, stop. Do not discard or overwrite them. Do not commit, push, publish, or delete files that are not needed.
- On an error, stop there and explain the cause and the next action needed. Do not work around signature or identifier mismatches. Leave launching the app and checking recording and text input to the user.

Steps:
1. Check for macOS 27 or later, the development tools, and the Apple silicon and Apple Intelligence requirements. Preflight checks for macOS 27 or later. Macs with Core 3 have not been verified.
2. Identify the currently installed ItJustTalks.app and its version, and confirm it is a regular app, not a symlink or another product. Ask the user to save their work and quit ItJustTalks, and confirm it has quit. Do not touch the app's data folder.
3. Check the source's remote, branch, and git status --short. Stop on uncommitted changes, conflicts, or a different source. Use a source obtained with git clone https://github.com/GrShin5/ItJustTalks, not a ZIP download. Do not use Desktop, Documents, iCloud Drive, or File Provider storage; if needed, make a new clone at, for example, ~/Developer/ItJustTalks, and use the tag or commit the user chose as the update target. Do not switch to main or discard local changes on your own. Report the current version, the target version, and the commit.
4. Read Appendices B and D of docs/manual/en.md and the scripts, then run bash scripts/preflight.sh. Detecting the existing app is expected during an update, but do not ignore other failures. Reuse the existing certificate, and distinguish a missing certificate from an unreachable keychain and from an untrusted certificate. If a new one is needed, get prior approval and run bash scripts/make_signing_cert.sh, but stop the update if the signature does not continue from the old version.
5. Keep the confirmed path of the old app in a shell variable previous_app and run bash scripts/verify_app_identity.sh "$previous_app". If it fails, do not proceed with a signature migration on your own.
6. Run bash scripts/make_app.sh release --previous-app "$previous_app". Then confirm continuity of the bundle ID, signer, and designated requirement with bash scripts/verify_app_identity.sh "$previous_app" dist/ItJustTalks.app. On a mismatch, do not move the old app; stop.
7. install_app.sh does not overwrite an existing app. Show the verified new version, the backup location, the install location, and the recovery steps concretely, and get the user's consent right before moving the old app aside. Do not delete the old version; create a unique backup folder on the same local disk outside sync storage and move it there. Do not overwrite existing items, and verify the old version again after moving it. If you lack permission to move it, leave the Finder operation to the user.
8. Confirm the install location is empty, then run bash scripts/preflight.sh --install and bash scripts/install_app.sh in that order. Compare the installed new version with the backed-up old version using the two-argument form of verify_app_identity.sh. If anything fails, stop and keep the old version. For recovery, check the install location; if a failed new version remains, move it aside separately as well, then guide the user to move the old version back to the original, now-empty location. Do not delete conflicting items on your own.
9. Have the user launch the new version and check settings, history, the dictionary, the microphone, the keys, and input of a short synthetic sentence. Do not promise that permissions carry over, and do not reset everything when problems occur. Keep the old version's backup until the checks are complete.
10. Briefly report the versions before and after, the commit used, the signature-continuity verification, the install and backup locations, unchecked device items, and the recovery steps.

Script output follows the ITJUSTTALKS_LANG environment variable (ja or en), otherwise the locale; it is Japanese when the locale is unset, C, or POSIX. Prefix the scripts with ITJUSTTALKS_LANG=en if the user reads English.
```
