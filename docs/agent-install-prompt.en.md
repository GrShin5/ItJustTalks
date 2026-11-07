# ItJustTalks installation prompt

Check the distributor, then paste the entire code block below into an AI coding agent that can work with local Mac folders and run commands. You do not need to attach any personal data. The agent's own network use is separate from the app's local AI processing.

The [Japanese version](agent-install-prompt.md) has the same content.

```text
Build, self-sign and install ItJustTalks 0.1.1 from source as a new installation on this Mac.
Source: https://github.com/GrShin5/ItJustTalks

Rules:
- Work only on ItJustTalks. AI processing uses only the on-device model in Apple Foundation Models. Do not install external AI tools, sign in to them, or set up API keys.
- Never upload user data. Do not read, print, or send the contents of speech, mail, selected text, the clipboard, the dictionary, history, or settings. Do not upload diagnostic information, and leave sensitive values out of your reports. Limit network use to fetching the specified source and required development dependencies.
- Do not change security settings. Do not weaken Gatekeeper, SIP, the privacy permission database, or Keychain protection, and do not disable verification, use ad-hoc signing, or reset all permissions. Leave macOS authentication and permission prompts to the user.
- Do not touch Koedex's app, repository, or data. Reading, writing, migrating, deleting, or changing permissions of `~/Library/Application Support/Koedex*` is prohibited.
- If you find modified sources or conflicts, stop. Do not discard or overwrite them. Do not commit, push, publish, or delete files that are not needed.
- On an error, stop there and explain the cause and the next action needed. Do not work around signature or identifier mismatches. Leave launching the app and checking recording and text input to the user.

Requires macOS 27 or later. AI features require Apple silicon, Apple Intelligence turned on, a ready model, and matching Mac and Siri languages. Command Line Tools (Apple tools for building from commands, including Git) are sufficient. Full Xcode is not required (Xcode 27 also works). No Homebrew or OpenSSL 3 installation is needed. You need an account that can write to /Applications (normally an administrator) and 2 GB free space.
0.1.0 was installed on an Apple M1 MacBook Air (8 GB memory, macOS 27.2, full Xcode 27.2). 0.1.1 was verified with Command Line Tools only: built on an Apple M5 Max and newly installed on an Apple M1 MacBook Air (macOS 27.2). Installation on a Mac without OpenSSL 3 is not yet verified. Macs with Core 3 remain unverified.

Steps:
1. First perform read-only checks: macOS version, Command Line Tools presence, whether ~/Developer/ItJustTalks is outside Desktop, Documents, iCloud Drive and File Provider storage, and whether /Applications/ItJustTalks.app exists.
2. Then get approval in ONE message for all of these: (1) cloning into ~/Developer/ItJustTalks and writing there; (2) if needed, creating the "ItJustTalks Dev" certificate, registering it in the login keychain, and trusting it for code signing only; (3) placing the app in /Applications; (4) if the agent has a restricted sandbox, running outside it only for scripts/install.sh and the scripts it calls. Explain the screens the user handles: the Command Line Tools installation dialog only if missing; Keychain authentication (Touch ID / password; it can appear once or twice during installation, and the user approves each); and after installation, launch from Finder and Microphone, Speech Recognition and Accessibility permissions. Stop if declined. Approval does not permit other protection changes.
3. If Command Line Tools are missing, ask the user to run/approve xcode-select --install and wait for completion. Full Xcode is not needed. Never ask the user to create a certificate by hand. Keychain Access instructions are a last resort only if the script fails and directs you there.
4. Use git clone https://github.com/GrShin5/ItJustTalks ~/Developer/ItJustTalks, not ZIP. Check the remote, branch and git status --short, including for an existing clone. Stop on a different source, modified sources or conflicts. Read Appendix B of docs/manual/en.md, scripts/install.sh and every script it calls before running them.
5. In the source folder run ITJUSTTALKS_LANG=en bash scripts/install.sh --allow-signing-cert. Toolchain problems are detected before certificate work. The certificate is reused. Stop on duplicate (multiple exact-name certificates) or inaccessible (Keychain error); never create another. On exit 3, relay the "What you need to do" message to the user (usually the authentication dialog was closed or timed out). When the user is ready, rerun the same command and have the user approve the macOS authentication dialog that appears during it. On exit 2 or any other error, stop and explain. Never overwrite or move an existing app; point to the update prompt if it differs. If an app built from the same source is already installed, it reports that and exits.
6. Briefly report the installed path, version from Info.plist, source commit, verification results and remaining user actions. Guide the user to launch from Finder, allow Microphone / Speech Recognition / Accessibility, check Apple Intelligence and matching Mac / Siri languages, and try a short synthetic sentence. A successful install or build is not a passed device test.

An agent sandbox (a restricted command execution area) can cause failures in the Swift plugin server, signature trust checks (CSSMERR_TP_NOT_TRUSTED), Keychain access, or writes to ~/Developer or /Applications even when the Mac is fine. The signer field in `codesign -dvv` output may also show Authority=(unavailable); that alone does not mean a different signer. Check signatures with scripts/verify_app_identity.sh, and stop if it fails. Rerun with the approved execution scope. Never disable verification to get past these errors.

Script output follows the ITJUSTTALKS_LANG environment variable (ja or en), otherwise the locale; it is Japanese when the locale is unset, C, or POSIX. Prefix the scripts with ITJUSTTALKS_LANG=en if the user reads English.
```
