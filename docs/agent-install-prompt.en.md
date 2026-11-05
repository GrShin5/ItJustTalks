# ItJustTalks installation prompt

Check the distributor, then paste the entire code block below into an AI coding agent that can work with local Mac folders and run commands. You do not need to attach any personal data. The agent's own network use is separate from the app's local AI processing.

The [Japanese version](agent-install-prompt.md) has the same content.

```text
Build ItJustTalks 0.1.0 from source on this Mac, sign it with a self-signed certificate, and install it as a new installation.
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
1. Confirm the Mac runs macOS 27. AI requires Apple silicon, Apple Intelligence turned on, the model prepared, and matching Mac and Siri languages. Verified on Apple M5 Max (64 GB memory). M1 (8 GB memory) verification is planned. Macs with Core 3 have not been verified. The exact compatible development-tool versions have not been verified; Swift 6.4 or later alone does not guarantee SDK compatibility.
2. In a local working folder outside sync storage chosen by the user, confirm the source and the destination. Get the source with git clone https://github.com/GrShin5/ItJustTalks, not a ZIP download. Do not use Desktop, Documents, iCloud Drive, or File Provider storage; use, for example, ~/Developer/ItJustTalks. For an existing clone, check the remote, branch, and git status --short, and stop if the source differs or there are uncommitted changes. Read Appendix B of docs/manual/en.md and the scripts involved, and confirm what they do.
3. Run bash scripts/preflight.sh. Preflight checks for macOS 27 or later. Do not ignore failures; if the only problem is a missing certificate, handle it in the next step. If development tools or OpenSSL 3 must be added, explain what is needed and leave it to the user.
4. Reuse a valid existing ItJustTalks signing identity. If there is no certificate, get the approval described above, then run bash scripts/make_signing_cert.sh and let the user handle the authentication dialog. Do not treat an unreachable keychain or an untrusted certificate as a missing certificate. Run preflight again and confirm the problem is resolved.
5. Run bash scripts/make_app.sh release, then verify with bash scripts/verify_app_identity.sh dist/ItJustTalks.app.
6. After bash scripts/preflight.sh --install succeeds, run bash scripts/install_app.sh. If ItJustTalks.app or an item with the same name already exists, do not overwrite it; point the user to the update prompt and stop.
7. Identify the installed app, verify it with verify_app_identity.sh, and confirm it matches the built app. Briefly report what was created, where it was placed, the version, the verification results, and what remains unchecked.
8. Guide the user to launch the app from Finder, allow Microphone, Speech Recognition, and Accessibility, check the Apple Intelligence status, and test the keys and input with a short synthetic sentence. Do not call a successful build a passed device test.

Script output follows the ITJUSTTALKS_LANG environment variable (ja or en), otherwise the locale; it is Japanese when the locale is unset, C, or POSIX. Prefix the scripts with ITJUSTTALKS_LANG=en if the user reads English.
```
