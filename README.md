# Peakbar

A macOS menu bar indicator showing whether the DeepSeek API is currently on peak or off-peak
pricing, with a countdown to the next change.

Red means peak. Green means off-peak.

## Why

DeepSeek bills its API at two rates: peak, and off-peak at half price. Peak is Beijing time, Monday
to Friday, 09:00 to 12:00 and 14:00 to 18:00, excluding Chinese public holidays. Everything else is
off-peak, including weekends and public holidays in full.

Scheduling batch work around that saves real money, and getting it wrong costs real money. This app
answers one question and answers it correctly: is it peak right now, and how long until that
changes.

## Install

Requires macOS 14 or later.

    git clone https://github.com/12345nikhilkumars/peakbar
    cd peakbar
    make install

`make install` builds, bundles, ad-hoc signs and copies `Peakbar.app` to `/Applications`. The app is
not notarized, so macOS may ask you to approve it in System Settings, under Privacy and Security, on
first launch.

There is no Dock icon. Click the menu bar item for details.

## What it shows

The menu bar title reads `PEAK 2h45m` or `OFF-PEAK 1h05m`, coloured red or green. Clicking it shows
the current phase, the time remaining, the exact instant of the next change in both Beijing and
local time, and two toggles: notify on rate change, and launch at login.

## Accuracy

The rule is not as simple as it looks, and most implementations get at least one part of it wrong.

- **The weekday is read off the Beijing calendar, never off UTC.** DeepSeek's weekend runs from
  16:00 UTC Friday to 16:00 UTC Sunday. An implementation that reads the weekday off the UTC instant
  agrees with the correct one at all 168 hours of the current schedule, so no test written against
  the live windows can detect it.
- **The countdown skips weekend and holiday resident edges.** From Beijing Friday 18:30 the next
  real change is Monday 09:00, about 63 hours later. A countdown that stops at the next nominal
  window edge reaches zero with nothing changing.
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

Requires the Xcode Command Line Tools. Xcode itself is not needed, and there is no Xcode project, no
SwiftPM manifest and no third-party dependency.

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
