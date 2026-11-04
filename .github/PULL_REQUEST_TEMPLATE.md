## What changed

## How it was tested

<!-- Where it ran (Mac, iOS Simulator, which iPhone), how far it booted, run logs or screenshots -->

## Checklist

- [ ] No Apple firmware, keys or files extracted from firmware
- [ ] No UDIDs, pairing files, signing team IDs, absolute local paths or other personal data
- [ ] If QEMU changed: the patches in `patches/` are exported again and apply in order to a clean upstream work tree
- [ ] The default behavior of the A4 and older machines is unchanged (new behavior sits behind a property that is off by default)
- [ ] If behavior changed: there is a write-up in `docs/reports/`
- [ ] Commits that touch QEMU carry `Signed-off-by`
