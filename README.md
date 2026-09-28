# Peakbar

A macOS menu bar indicator showing whether the DeepSeek API is currently on peak or off-peak
pricing, with a countdown to the next change.

Red means peak. Green means off-peak.

## Features

- **Menu bar title** reading `PEAK 2h45m` or `OFF-PEAK 1h05m`, coloured red for peak and green for
  off-peak, at minute resolution.
- **Click for detail**: the current phase, the time remaining, and the exact instant of the next
  change in both Beijing and local time.
- **Rate change notifications**, so you hear about a flip without watching the clock. A flip that
  happened while the Mac was asleep is suppressed rather than replayed hours late.
- **Launch at login**, on by default and toggleable.
- **Holiday aware**, including make-up workdays, from Apple's China holiday calendar.
- **Needs-based fetching**: roughly 49 requests a year rather than 365, because it only fetches when
  a fetch can change an answer.
- **Fails safe**. If the current year's holiday arrangement is not published yet, the app says so and
  assumes peak, so it never under-reports the price.
- **No account, no API key, no telemetry**, and no network beyond the single calendar fetch.
- **No Dock icon**. It lives in the menu bar.

## Resource usage

Measured on macOS 27 on Apple silicon, after a 60 second settle:

| | |
|---|---|
| Memory, physical footprint | **13 MB**, peak 14 MB |
| CPU at idle | average **0.0004%**, peak **0.0082%** |

The CPU figure comes from a 120 second sample. The only non-zero readings are two small spikes about
60 seconds apart, which are the once-a-minute refresh. Between them the process uses no measurable
CPU at all.

There is no polling loop. A single non-repeating timer is rescheduled to the exact next change, and
the app recomputes on wake, clock change, timezone change and day change.

For scale: an empty AppKit menu bar app with one status item and no logic of its own measures about
11.5 MB, so most of the 13 MB is AppKit rather than this app.

## Install

### From source (recommended)

Requires macOS 14 or later and the Xcode Command Line Tools. Xcode itself is not needed.

    git clone https://github.com/12345nikhilkumars/peakbar
    cd peakbar
    make test        # optional, runs the suite
    make install

`make install` compiles, assembles the bundle, ad-hoc signs it and copies `Peakbar.app` to
`/Applications`.

**This is the better option.** You can read every line that goes into the binary first, you can run
the tests yourself, and you skip the quarantine step described below entirely.

### From the disk image

Download `Peakbar-1.0.0.dmg` from the
[releases page](https://github.com/12345nikhilkumars/peakbar/releases/latest), open it, and drag
**Peakbar** onto the **Applications** folder shown beside it. Then eject the image and launch Peakbar
from Applications. There is no installer.

The app is ad-hoc signed but **not notarized by Apple**, so macOS will refuse to open it the first
time. Two ways past that:

1. Open System Settings, go to Privacy and Security, and approve the app after attempting to launch
   it once. See
   [Apple's instructions](https://support.apple.com/en-us/102445).
2. Or clear the quarantine flag from the terminal:

       xattr -d com.apple.quarantine /Applications/Peakbar.app

The second is quicker but means trusting a binary you have not built. If that matters to you, build
from source instead.

## What it shows

The menu bar title reads `PEAK 2h45m` or `OFF-PEAK 1h05m`, coloured red or green. Clicking it shows
the current phase, the time remaining, the exact instant of the next change in both Beijing and local
time, and two toggles: notify on rate change, and launch at login.

## Accuracy

The rule is not as simple as it looks, and most implementations get at least one part of it wrong.

- **The weekday is read off the Beijing calendar, never off UTC.** DeepSeek's weekend runs from
  16:00 UTC Friday to 16:00 UTC Sunday. An implementation that reads the weekday off the UTC instant
  agrees with the correct one at all 168 hours of the current schedule, so no test written against
  the live windows can detect it.
- **The countdown skips weekend and holiday resident edges.** From Beijing Friday 18:30 the next real
  change is Monday 09:00, about 63 hours later. A countdown that stops at the next nominal window
  edge reaches zero with nothing changing.
- **The effective date is evaluated per candidate, not once on "now".** The weekend rule took effect
  on 23 August 2026 and is not retroactive.

Correctness is checked against an independent implementation of the rule across 1,578,240 instants,
and against the CC0 conformance suite from
[xyzs996/deepseek-peak-hours](https://github.com/xyzs996/deepseek-peak-hours).

## Holidays

Holiday dates come from Apple's China holiday calendar, which carries the statutory arrangement
including make-up workdays. It is fetched only when a fetch can change an answer: on launch, and at
most once per day inside a window around the new year, or when the data on hand is stale or
unreadable. That works out at roughly 49 requests a year rather than 365.

If the current year's arrangement has not been published yet, the app says so and assumes peak, so it
never under-reports the price.

## Build

Requires the Xcode Command Line Tools. There is no Xcode project, no SwiftPM manifest and no
third-party dependency.

    make build     # compile
    make test      # run the test harness
    make bundle    # assemble Peakbar.app
    make sign      # ad-hoc sign it
    make install   # copy to /Applications
    make clean

`make test` is a plain executable harness rather than XCTest, because `swift test` does not work
without a full Xcode install.

## Licence

GNU Affero General Public License, version 3 or later. See `LICENSE`.

Third-party notices are in `NOTICE`.

## Disclaimer

Not affiliated with, endorsed by, or supported by DeepSeek. "DeepSeek" is the property of its owner.
