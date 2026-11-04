# Contributing to Slide to Unlock

Thanks for helping. Most of the rules below protect two things: no Apple material in the repository, and nobody's private data either.

## Never commit

- **Apple firmware and Apple files**: IPSWs, extracted kernels, iBoot, device trees, shared caches, root file systems, built devices, `.ctpack` files, firmware keys. They live in the ignored `work/` directory, never go into the repository and are never bundled into the app. For a step that needs firmware, describe how to fetch it from Apple's servers.
- **Personal data**: phone UDIDs, ECIDs, serial numbers, StikDebug pairing files, signing team IDs, Apple IDs, screenshots showing notifications or other apps. Scripts read these from files under `work/` or from environment variables (for example `work/ios/phone-udid` or `PHONE=`).
- Absolute paths on your machine (`/Users/yourname/...`). Scripts work out the project root from their own location.

Before committing you can run:

```bash
git diff --cached --stat
git diff --cached | grep -nE '/Users/|[0-9A-F]{8}-[0-9A-F]{16}|BEGIN .*PRIVATE KEY'
```

## Changing QEMU

- `upstream/` is a clone of upstream and is never edited directly. Make changes in a work tree under `work/`, then export them as a patch in `patches/` (`scripts/ios/export-patch.sh`). Start the patch with a description of what it changes and why.
- Patches must apply in the order `scripts/ios/build-qemu.sh` uses, on the pinned upstream commit (qemu-ios `b225694505`). Try that once in a clean work tree after changing them.
- Do not change the default behavior of the A4 and older machines. Put new behavior behind a property that is off by default, and keep the snapshot format unchanged.
- Add a `Signed-off-by` line to commits that touch QEMU (`git commit -s`, the [DCO](https://developercertificate.org/)) so the work can go back upstream later.

## Reports and documentation

- Write up each round of work, with its process and conclusions, in `docs/reports/`, and put screenshots in `docs/reports/img/`. Keep what was verified apart from what is inferred, and say which run each number comes from.
- The roadmap and the decisions made are in `docs/plan.md`.
- Everything in the repository is written in English: documentation, reports, code comments and commit messages.

## Opening an issue

- Say which device and OS version is emulated, where it runs (Mac, iOS Simulator, or which iPhone on which iOS version), where JIT comes from (StikDebug, a tethered Mac, none), the steps to reproduce, and the relevant logs.
- Look over logs and screenshots before posting and remove UDIDs, serial numbers and personal data.
- Do not post Apple files; link to Apple's own downloads instead.

## Opening a pull request

- One pull request does one thing. Say what changed and how you tested it, with run logs or screenshots.
- If you changed a patch, export it again and confirm it applies to a clean work tree.
- If you changed how the app behaves, boot at least one affected system in the iOS Simulator.

## License

Your contributions are licensed under GPL-2.0-or-later; patches to QEMU or FirmwareKit files keep the license of the files they change. See the [README](README.md#license).
