# Slide to Unlock

An iPhone app that runs stock iPhone OS 1 through iOS 10 on an iPhone, for anyone who wants to revisit classic iOS. The user widened the goal from 7.1.2 to iOS 10 on 2026-11-02. Upstream emulation stops at iOS 7.1.2; iOS 8 to 10 need the A5 and A6 machines this project is adding. The user sees the project as a contribution to the open-source community: open source (GPL-2.0-or-later), distributed by sideloading.

Repository: [kurisu12h/slide-to-unlock](https://github.com/kurisu12h/slide-to-unlock), public since 2026-11-04. The project was called Classic Touch until then; internal names (bundle ID `org.classictouch.app`, the Xcode target and the local folder `~/Developer/ClassicTouch`) keep the old name. Commits use the GitHub noreply address set in this repository's git config.

## Roles

- **Decision session**: splits the work, dispatches sessions, and reports results to the user. Execution sessions never ask the user for decisions directly.
- **Execution sessions**: do only what the brief covers. Write the detailed report to `docs/reports/`, and end the round with a 3 to 5 sentence message giving the conclusion, the key numbers and what blocks progress (the decision session only sees about the first 400 characters).
- Anything outside the brief that the user has to decide (extra downloads, spending money, posting publicly or opening issues/PRs upstream, changing system settings, the Apple ID used for signing): stop, put the question in the report, and do not decide it yourself.

## Background (verified 2026-11-01)

- Engine: [samhenrigold/qemu-ios](https://github.com/samhenrigold/qemu-ios) (a QEMU 11 fork, GPL-2). The Mac app and the FirmwareKit firmware tooling are in [samhenrigold/LightTouchMac](https://github.com/samhenrigold/LightTouchMac) (GPL-2+).
- Upstream runs iPhone OS 1.0 through iOS 7.1.2 on a Mac across 8 machines (original iPhone, 3GS, iPhone 4, iPod touch 1st to 4th gen, original iPad). Graphics forward OpenGL ES calls to the host GPU (CGL, or the experimental ANGLE).
- Light Touch's README says it will not do iOS, Android or web versions, or newer devices and versions. An iPhone version did not exist.
- Upstream ran on a real A19 iPhone on 2026-08-04 (dylib embedded in an app), then on 08-05 marked it a "dead end" and moved to the Mac app, for performance: the author concluded a release build cannot get JIT, and the pure interpreter runs at about a tenth of real speed, one or two frames per second. The iOS build scripts were deleted on 10-13, but the TXM JIT path in `tcg/region.c`, `hw/arm/gles-host-eagl.c` and the app ABI in `contrib/ios-app/qemu-ios-ui.c` are still on the main branch. See `docs/research/m1-iphone-feasibility.md`.
- **Conclusion: from iOS 4 on, JIT is required for the guest to be usable** (a debugger-based approach such as StikDebug; iOS 27 needs the TXM protocol).
- Similar projects: S5LBox (an emulator written from scratch, runs iPhone OS 3.1.3 on an iPhone, MIT); pocketTouch (closed-source IPA, claims to be an iOS port of Light Touch, runs 1 to 3, unverified); Inferno-iOS (runs iOS 14 on an iPhone); c12n/nexttouch (empty repository that says it will do iOS 8 to 10); Podium by Leviidev (iOS 6.1.6 on an emulated iPod touch 4 inside an iPhone app); NastyaKus/qemu-ios10 (public, started 2026-11-04, an A6 iPhone 5 machine for iOS 10.3.3 that does not reach the kernel console yet). Android port: KD3533/qemu-ios-android.

## Layout

- `upstream/`: clones of the upstream repositories. Never edit them; save needed changes as patches in `patches/` with the reason written in the patch.
- `work/`: build products, firmware, device images, snapshots. Large; never committed.
- `docs/plan.md`: the roadmap and decisions made. `docs/reports/`: session reports (screenshots in `docs/reports/img/`). `docs/research/`: research.

## Rules

- Everything in the repository is written in English: documentation, reports, code comments, commit messages and PR descriptions. Replies to the user in conversation are in Chinese. In both, avoid em dashes.
- Apple firmware never goes into the repository and is never bundled into the app. Users download it themselves; the app only fetches it from Apple's servers (or the mirrors in upstream's firmware table).
- Do not commit, push, open PRs or file upstream issues unless the user asks.
- Never in the repository: phone UDIDs (scripts read `work/ios/phone-udid`), StikDebug pairing files (`work/ios/secrets/`), signing team IDs, information about other apps and accounts on the user's phone, screenshots with personal data, absolute paths of the local machine.
- Never put anything in `~/Desktop` or `~/Documents` (iCloud-synced, slows builds down).
- Run long commands such as builds and device creation in the background.
- This machine: M4 Max (36 GB), macOS 27, Xcode 27.2, about 319 GB of free disk.
