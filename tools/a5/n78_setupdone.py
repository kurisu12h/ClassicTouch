#!/usr/bin/env python3
"""Setup Assistant's finished state for 9.x (13G36) on the n78, seeded into a mounted data volume (/private/var).

    n78_setupdone.py VAR [LANGUAGE [LOCALE]]      (defaults en, en_US)

FirmwareKit's FinishedSetup stops at 7.x (keys diffed from walks on n90 11D257) and has no 9.x recipe, so this is
a superset rather than a diff: SetupFinishedAllSteps and SetupDone, and every step's ...Presented key that 13G36's
Setup.app or the shared cache names (Setup marks each step it shows by one; a key from another release is
ignored). SetupVersion 7 is a guess for 9.x (6.x writes 3, 7.x 5). The 7.x cloud configuration record is kept
(without it 7.x's PSSetupAssistantNeedsToRun brings Setup back). Existing plists are merged into, and new files
take the caller's uid, which is mobile's (501) on this host.

What decides on 9.x is simpler than the keys (SetupAssistant.framework's BYSetupAssistantNeedsToRun, which
SpringBoard imports): com.apple.purplebuddy ForceNoBuddy true answers NO; otherwise Setup runs unless
/tmp/com.apple.purplebuddy.sentinel exists, which the Setup side writes once it is done. ForceNoBuddy is set.
"""
import os, plistlib, sys, time

PRESENTED = (
    # 13G36 Setup.app
    "ActivationLockPresented", "AppleIDPB9Presented", "CloudConfigPresented", "KeychainSync3Presented",
    "LocationServices5Presented", "MagnifyPresented", "Mesa2Presented", "MesaPurchasesPresented",
    "PBAppActivity2Presented", "PBDiagnostics2Presented", "PBTCPresented", "Passcode4Presented", "Payment2Presented",
    "TrueTonePresented", "WiFiPresented",
    # 13G36 shared cache (SpringBoard and the Setup frameworks)
    "AppleIDPB6Presented", "AssistantPresented", "PBAppActivityPresented", "Passcode2Presented",
    # 7.x names the n78 7.1.2 walk needed (report 3.15.2), harmless if 9.x renamed them
    "AppleIDPB5Presented", "PasscodePresented", "KeychainSyncPresented", "PBEmailUpdatesPresented",
    "PBDiagnosticsPresented", "LocationServices2Presented",
)


def merge(path, keys):
    d = {}
    if os.path.exists(path):
        with open(path, "rb") as f:
            d = plistlib.load(f)
    d.update(keys)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        plistlib.dump(d, f, fmt=plistlib.FMT_BINARY)


def main(var, language="en", locale="en_US"):
    prefs = os.path.join(var, "mobile/Library/Preferences")
    buddy = dict.fromkeys(PRESENTED, True)
    buddy.update(ForceNoBuddy=True, SetupDone=True, SetupFinishedAllSteps=True, RestoreChoice=True, SetupVersion=7,
                 SetupState="SetupUsingAssistant", SetupLastExit=int(time.time()), Language=language,
                 Locale=locale, AppleIDForceUpgrade=False)
    merge(os.path.join(prefs, "com.apple.purplebuddy.plist"), buddy)
    merge(os.path.join(prefs, "com.apple.purplebuddy.notbackedup.plist"),
          {"LocationServices2Presented": True, "LocationServices5Presented": True, "CloudConfigPresented": True})
    merge(os.path.join(prefs, "com.apple.mobile.user_preferences.plist"),
          {"UserSetLanguage": True, "UserSetLocale": True})
    merge(os.path.join(var, "mobile/Library/ConfigurationProfiles/CloudConfigurationDetails.plist"),
          {"AllowPairing": True, "CloudConfigurationUIComplete": True, "IsSupervised": False,
           "PostSetupProfileWasInstalled": False})
    print("n78_setupdone: %d Setup keys, SetupVersion 7" % len(buddy))


if __name__ == "__main__":
    main(*sys.argv[1:4])
