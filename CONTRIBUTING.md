# Contributing

Issues and pull requests are welcome.

## Setup

Requires macOS 14+ and Xcode 15+ (or the matching Swift toolchain).

```bash
make test          # unit tests (RamRadarCore)
make run           # build RamRadar.app and open it
.build/debug/RamRadar --dump          # one check, printed to the terminal
.build/debug/RamRadar --dump --demo   # same, with built-in sample data
```

## Layout

| Path | What |
|---|---|
| `Sources/RamRadarCore` | Sampling (libproc, Mach, sysctl), grouping, suggestion rules, stopping. No UI; fully unit-tested. |
| `Sources/RamRadar` | Menu-bar app: status item and dropdown panel, model, stop flow, browser-tab reader, CLI modes. |
| `Sources/RamRadar/Views` | SwiftUI views (Swift Charts for the donut). |
| `Tests/RamRadarCoreTests` | XCTest suite. `StopperTests` spawns and kills real child processes. |

## Testing the timer

`RAMRADAR_CHECK_SECONDS=20 build/RamRadar.app/Contents/MacOS/RamRadar` checks every 20 seconds
instead of the configured interval. Each check logs one line:

```bash
log stream --info --predicate 'subsystem == "io.github.gemscng.RamRadar"'
```

## Changing a suggestion rule

Rules live in `SuggestionEngine.swift` and `SuggestionRules`. Add a test in
`SuggestionEngineTests.swift` for the case you're adding and one for a case it must
not flag. A false "stop this" suggestion costs users more than a missed one.

## Screenshots

`make screenshots` renders `docs/screenshot-*.png` from `--demo` data, so no real
process names or paths end up in the repo.
