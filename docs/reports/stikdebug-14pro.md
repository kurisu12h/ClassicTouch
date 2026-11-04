# StikDebug on the iPhone 14 Pro: JIT without the Mac

- Date: 2026-11-04
- Execution session: a5-nand (after `docs/reports/a6-app.md` and `docs/reports/ios-device-14pro.md`).
- The user asked to install StikDebug on the iPhone 14 Pro (iPhone15,2, iOS 27.0.1, 24A446), then approved downloading `idevice-tools` and generating a pairing file.
- Not done: no commit or push; nothing in the repository holds the pairing file, the phone's UDID or the signing team ID; the iPhone 18 Pro was not touched.

## 0. Conclusions

1. **StikDebug gives JIT on iOS 27.0.1: yes.** With LocalDevVPN on, StikDebug prepares the 256 MiB code buffer on the phone in 1.1 to 1.3 s (tethered LLDB took 40 to 43 s). No Mac is needed for JIT. M1 had only tried StikDebug on iOS 27.2.
2. **Boot times without the Mac** (one boot each, `STIK=1 scripts/ios/device-boot.sh`, the app's autodrive unlocks):

   | System | Code buffer | First frame | Lock screen | Home screen | Unlock tries | Max footprint |
   |---|---:|---:|---:|---:|---:|---:|
   | iOS 10.3.4 (iPhone 5) | 1.19 s | 1.9 s | 100 s | 102 s | 1 | 1420 MB |
   | iOS 9.3.5 (iPod touch 5) | 1.28 s | 2.0 s | 80 s | 172 s | 8 | 1219 MB |
   | iOS 7.1.2 (iPod touch 5) | 1.14 s | 1.8 s | 41 s | not reached | 12, all failed | 1061 MB |

3. **The remaining blocker on the phone is the app's synthetic slide-to-unlock** for iOS 7 and 9 (the same problem as `ios-device-14pro.md` 7.4). It is not JIT: every boot reached the lock screen. iOS 10 opens with a Home press and needs no slide, so it unlocks first time.
4. The first StikDebug attempt failed because LocalDevVPN was off ("Device not connected", `Failed to create tunnel: connect: Operation Timeout`, target 10.7.0.1:49152). LocalDevVPN has to be on whenever StikDebug gives JIT.

## 1. Building and installing StikDebug

- Source: tag **3.2.0** (commit 97530a9, the release M1 used), shallow-cloned into `work/ios/stikdebug/` (199 MB). Its two Swift packages (CodeEditorView, Rearrange) came from the local package cache. StikDebug is AGPL-3.0; it stays in `work/` and is not built into our app.
- Built Release with the user's paid team and automatic signing, as in `m1-stage3-stikdebug.md` section 1. All changes are overrides on the `xcodebuild` command line; its project files are unchanged:
  - `PRODUCT_BUNDLE_IDENTIFIER=org.classictouch.dev.stikdebug` (the original ID belongs to another team);
  - `CODE_SIGN_ENTITLEMENTS` pointing to an empty local entitlements file (`work/ios/stikdebug-local.entitlements`), which drops the App Group that belongs to another team. The signed app carries only `get-task-allow` besides the team and app identifiers.
- Profile: the team's wildcard development profile, which includes the 14 Pro since `ios-device-14pro.md` section 6. Installed with `devicectl device install app`.
- Preferences written into its container before the first launch, as M1 did, so that `stikjit://` launches from scripts do not prompt: `confirmExternalJITRequests = false`, `keepAliveLocation = false`.

## 2. idevice-tools and the pairing file

- `idevice-tools-macos-arm-v0.1.68.zip` from the idevice project's GitHub release v0.1.68: 5583721 bytes, SHA-256 `fc4c2a74a3d2899bc33a7c2ed42d367e843b9dd6854bb3b1b257274b1ce712fa`, matching the digest GitHub lists for the asset. Unpacked to `work/ios/tools/idevice-tools-0.1.68/bin/`, where the scripts look for it. With it present, `scripts/ios/devfiles.sh` uses AFC again instead of `devicectl`.
- Pairing file:
  - `idevice-tools --udid <the 14 Pro> remotepairing_lockdown pair <host name> <file>` over USB, using the Mac's existing trust; no prompt on the phone.
  - `remotepairing_lockdown verify`: "the device recognizes this pairing record".
  - The file (an RPPairing record) is in `work/ios/secrets/`, directory 700 and file 600, ignored by git. It was copied to StikDebug's `Documents/pairingFile.plist`; StikDebug takes it in on launch.
- On its first launch StikDebug fetched a developer disk image into its own `Documents/DDI/` (15.9 MB). That download is StikDebug's own, made by the phone.

## 3. Runs

All with `PHONE=… STIK=1 IDLE=20 scripts/ios/device-boot.sh <device> jit 420`.
- The Mac writes the app's `autostart.json` over AFC and opens `stikjit://enable-jit?bundle-id=org.classictouch.app&script-name=universal.js`.
- StikDebug starts our app and answers the code buffer request with `universal.js`.
- The app boots, recognizes the lock and home screens, unlocks, idles 20 s and quits. The Mac only polls `events.log`.

| Run (`work/ios/runs/device/`) | System | Result |
|---|---|---|
| `20261104-231242-n41ap-14G61-jit` | iOS 10.3.4 | Code buffer 1.19 s, lock 100.3 s, one Home press, home 102.2 s, clean exit; footprint 1383 MB at the lock screen, max 1420 MB, min available 1652 MB |
| `20261104-231623-n78ap-13G36-jit` | iOS 9.3.5 | Code buffer 1.28 s, lock 80.3 s, the slide worked on the 8th try, home 172.3 s, clean exit; max 1219 MB |
| `20261104-232044-n78ap-11D257-jit` | iOS 7.1.2 | Code buffer 1.14 s, lock 41.2 s, 12 slides all failed, then the guest's screen went off; the script quit QEMU at its 420 s limit; max 1061 MB. The lock screen showed no "Cannot Use Device" notice (the rebuilt 7.1.2 pack, `ios-device-14pro.md` 7.5) |

Without the code buffer preparation, the times to the lock screen match the tethered runs:
- iOS 10: 144 s tethered, minus 43 s of preparation, is about 101 s, against 100 s here;
- iOS 9.3.5: 128 to 133 s tethered (`ios-device-14pro.md` 7.4), against 80 s here;
- iOS 7.1.2: 78 to 80 s tethered, against 41 s here.

Screenshots (guest screen only, no personal data):
- iOS 10.3.4 home screen: `docs/reports/img/a6-app-14pro-stik-home.png` (105 s, run `20261104-231242-n41ap-14G61-jit`);
- iOS 9.3.5: `docs/reports/img/stik14pro-935-lock.png` (80 s) and `stik14pro-935-home.png` (172 s), run `20261104-231623-n78ap-13G36-jit`;
- iOS 7.1.2 lock screen: `docs/reports/img/stik14pro-712-lock.png` (44 s), run `20261104-232044-n78ap-11D257-jit`.

At the end the app was ended on the phone and nothing was left running on the Mac.

## 4. What is left

- **The synthetic slide-to-unlock** on the phone for iOS 7 and 9. The app presses Home, then 5 s later drags from 18% to 92% of the width at 90% height over 600 ms in 20 steps. On the phone it works sometimes (2 to 8 tries) and often not at all within 12 tries; in the simulator it works in 1 to 3 tries. Nothing about touch shows in the QEMU or serial logs. A user unlocking by hand was not tried. The next step is in `app/` (slower or longer drags, or checking how the guest's multitouch driver sees them), which the decision session asked to leave until the English merge is done.
- Repeated boots for statistics; the interpreter backend; Settings on the phone.
- StikDebug needs LocalDevVPN on; the user turns it on on the phone.
