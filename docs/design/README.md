# UI design proposals (M2 UI, step 1)

- Date: 2026-11-02, execution session m2-ui. The user felt the App prototype was "a bit ugly", so here are three proposals in clearly different directions to choose from; the chosen one gets implemented afterwards.
- **Result: the user chose A "Timeline" (the redone version). The home page is implemented, and the new look of the emulator screen is written and waiting to be wired in; see step 2 in `docs/reports/m2-ui.md`.**
- Side-by-side comparison at a glance: `docs/reports/img/ui-overview.png` (all three side by side, two screens each plus notes).
- Single screens at full size (1206 × 2622, the same size as an iPhone 18 Pro screenshot): `docs/reports/img/ui-{a,b,c}-{home,run}.png`; home is the home page, run is the running screen.
- Mockup sources: `mockups/*.html` (one screen per page, 402 × 874 pt); shared parts are in `mockups/common.css` and `common.js`. After editing, run `docs/design/render.sh` to regenerate the images (it needs Google Chrome installed on this machine, takes screenshots in headless mode, and downloads nothing).

## The three proposals

### A Timeline (`ui-a-home.png`, `ui-a-run.png`)

The first version of A (midnight blue background, amber glow, frosted glass cards, a year scale bar) got the user's verdict "not good-looking, too AI". It was redone entirely, keeping only the idea of "ordering by year".

Now it is black text on white, like a yearbook: one row per system, with the year in large condensed type on the left (the system's built-in DIN Condensed, which iOS also has, so nothing to download), the model, system version, build number and size on the right, and a line-drawn device body at the far right; rows are separated only by thin rules. Red is used to mark just two things: the one that is running (the year turns red, a red bar on the left, and a black "Resume" button next to it), and the iPod touch 2nd gen's "Experimental: may freeze after screen off". Years not imported (2007–08, 2010–11) are a single gray line of text; iOS 8 to 10 get a row "2014–16 · iOS 8, 9, 10 [Later]" in an even lighter color with a "Later" box, so it is clear they cannot be used yet. The JIT status sits in a black-outlined box at the bottom. The emulator screen switches to a black background so white edges do not compete with the guest screen: a large year "2012" at the top with the model and system, and below that three large square buttons (Timeline, Home, Power), with Home being the white one.

- Strengths: the sense of time comes from typography rather than effects, clean and with character; no glow, no gradients, and it does not imitate any generation of Apple's interface.
- Implementation effort: medium to small, about 600 lines. The home page is just a restyled ordinary `UITableView`, plus a small view for the line-drawn device body (`UIBezierPath`, three to four shapes).
- Watch out for: years are counted by the first release year of the major version (3.1.3 counts as 2009); the gray and "Later" rows are only hints, and tapping them shows the import instructions or the "supported later" note.

### B Nostalgic skeuomorphic (`ui-b-home.png`, `ui-b-run.png`)

A tribute to the textures before iOS 6: blue-gray gradient navigation bar, vertical pinstripe background, white rounded grouped tables, glossy glass buttons ("Resume" is an old-style green button, "Experimental" is a small orange badge, and the size is written in the blue-gray value on the right). The emulator screen has a dark linen background, and the guest screen sits inside a device body we draw ourselves, shown 1:1 with the original device (320 × 480 pt); tapping the round button on the body is Home, the button on top of the body is Power, and going back is an old-style arrow-shaped "Systems" button.

- Strengths: longtime players get a "we're back" feeling as soon as they open it, and the App feels of a piece with the old systems inside it.
- Implementation effort: the largest, about 1000 lines or more. The pinstripes, linen, gloss and device bodies are all drawn with Core Graphics (no images); 8 models need at least 4 device bodies, and the buttons on the body need a pressed effect.
- Watch out for: the screen is about 20% smaller than the current full-width layout; rough textures and gloss look cheap instead, so the details need several rounds of tuning.

### C Modern cards (`ui-c-home.png`, `ui-c-run.png`)

The same approach as current iOS: a large title "Pick a System", below it large horizontally swiping model cards, each card with a background color for its era, the major version number ("3.1.3"), and a device illustration whose screen shows this system's last screen before shutdown, with a large "Boot" button at the bottom; the one that is running sits at the bottom like a music player's mini bar. The emulator screen is all black, the guest screen fills the full width (402 × 603 pt, the same size as now), "‹ List" at the top left, and a glass capsule at the bottom holding Home and Power.

- Strengths: clean and consistent with the system's built-in Apps; the screen is the largest and clearest; the fastest to finish.
- Implementation effort: the smallest, about 500 lines. On iOS 26 and later it uses the system's glass material, and on 16 to 25 it falls back to frosted glass (the deployment target is iOS 16).
- Watch out for: the "last screen" in a card only exists once that system has been booted once; before that it shows a placeholder (the era's background color plus the version number). The App cannot ship screenshots of Apple's systems. Saving this image needs a few lines added in the emulator screen, to be wired in after the iOS 7 optimization session is done.

## What all three share

- The home page shows the model, system version, build number and storage used for every system; the iPod touch 2nd gen's "Experimental: may freeze after screen off" and the JIT status are kept in all three, only in different positions and styles. The import button at the top right is kept, and "Only one system can run at a time; the App restarts when you switch systems." is still there.
- The emulator screen always has three controls: back to the list, Home and Power; the run status (CPU, footprint) moves into "⋯" or "i" and no longer sits permanently at the top of the screen.
- The device bodies are all simplified shapes we draw ourselves as vectors, with no Apple logo, product photos or trademark wording; copy still goes through `Localizable.xcstrings` as before.
- The guest screens shown in the mockups are screenshots we ran ourselves (`mockups/assets/guest-*.png`, taken from `work/ios/runs/`), used only in the documentation and not shipped in the App.
- The target was extended to iOS 10 and later (decided 2026-11-02): only A lists not-yet-imported years by year, so only A reserves a "Later" row for iOS 8 to 10; B and C list only imported systems and do not show versions that cannot be used yet.
- Dialogs and prompts such as import progress, "No JIT" and "Switch systems" were not drawn this time; at implementation time they are restyled to match the chosen style, and the flow stays the same.

## They can be mixed

- The device body look can become a toggle on the emulator screen: add "Show device body" to A's or C's "⋯", and turning it on gives B's kind of body (smaller screen, buttons on the body). That way B's nostalgia can be added later without building all of it up front.
- B's home page (grouped tables) is actually not much work; the bulk is the textures and device bodies. If only the old flavor of the home page is wanted, it is possible to build just B's home page plus C's emulator screen.
- The "About" section (open source license, credits to qemu-ios and Light Touch) is only drawn in B, but all three can add it; for a GPL project, the license and upstreams should preferably be visible in the App.

## App name candidates (for reference; the user decides the name)

All avoid Apple trademarks such as iOS, iPhone and iPod; before deciding, check whether another App or a GitHub project already uses the name.

- **Shiguang (拾光)**: "picking up old times"; an easy-to-remember Chinese name that echoes the "Timeline" proposal.
- **Pinstripe**: a tribute to the vertical pinstripe background of the old Settings pages; longtime players get it at a glance, and it echoes the skeuomorphic proposal.
- **Throwback**: English for "a nostalgic look back"; straightforward.

## My preference

If only one is picked, I lean toward the new A: it reads the most clearly, has a look of its own, and is not much work. C is the safe fallback (least effort, largest screen), but it is not very different from a typical modern App. B has the most nostalgia but takes the most work, and can be added later as the "Show device body" toggle.
