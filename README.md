# carbonite

A fan curve for hwmon fans, applied through
[CoolerControl](https://gitlab.com/coolercontrol/coolercontrol). Gum-free and
flag-driven. The interactive front-end lives in
[scomp-link](https://github.com/malahmen/scomp-link).

The desktop sibling of
[thermal-exhaust-port](https://github.com/malahmen/thermal-exhaust-port), which
handles the case with no hwmon PWM.

## Why this exists

On an MSI PRO B760 (NCT6687 Super I/O, `nct6687` driver) every fan header is a
writable `pwmN`. Left alone, though, the BIOS curve is in charge. On this board
that meant one header pinned at 100% and the rest at a flat 60%, whatever the
temperature.

CoolerControl can already drive those headers. carbonite is **not a daemon**:
it writes a curve into CoolerControl over its REST API, and CoolerControl saves
it and re-applies it at boot.

| CoolerControl object | id | |
| --- | --- | --- |
| function | `carbonite-fn` | hysteresis + response delay, only on the way down |
| Graph profile | `carbonite-g-N` | one per watched sensor, same curve |
| profile | `carbonite` | the curve: the Graph (one sensor) or a Mix taking the max |
| profile | `carbonite-mN` | the same curve, never below N% (for fans that stall) |

Plus **pins**: a fan header held at a fixed duty whatever the temperature, for
an AIO pump.

Everything is read back from CoolerControl, so there is no second copy of the
curve here to drift from what is running. The one thing stored locally is which
fixed duties are carbonite's own pins, so a fixed speed set in the GUI is never
mistaken for one.

## Header labels lie

On the board this was written for, the AIO **pump** is on `CPU_FAN1` (label
"CPU Fan") and the **radiator fans** are on `PUMP_FAN1` (label "Pump Fan").
Many AIO manuals tell you to wire it that way. So carbonite never decides
anything from a label: `apply` requires `--channels`, and the pump is named
with `--pin`.

## Setup

```sh
# in CoolerControl: Settings → Access Tokens → new token WITH write access
./carbonite.sh login --token cc_…
./carbonite.sh sensors        # what can be watched
./carbonite.sh channels       # what can be driven
./carbonite.sh apply --curve "30:30 50:50 60:70 70:80 75:90 80:100" \
    --pin "7bfee7e1:fan1@100" \
    --channels "7bfee7e1:fan2@45 7bfee7e1:fan3 7bfee7e1:fan4"
```

The token is saved to `~/.config/carbonite/config` (mode 600). `$CARB_TOKEN`
overrides it. Needs bash 4+, curl, jq and a running `coolercontrold`. No root.

## Commands

```
login --token TOKEN      save a CoolerControl access token (needs write access)
check                    is the daemon reachable and is the token accepted
status                   applied curve, sensors, channels, temps, fan RPM
sensors                  TSV: id  device  label  degC  watched
channels                 TSV: id  device  label  rpm  duty  control
                         control: -  curve  curve:N  pin:N  fixed:N (set elsewhere)
curve                    the applied curve as TSV: degC  duty
simulate T...            walk a curve over temperatures, change nothing
apply                    write the curve; --channels is the full list on it
set-curve POINTS         change the applied curve, keep sensors, channels, floors
pin ID@N...              hold channels at N% (a pump: ID@100)
unpin ID...              hand pinned channels back to the board
release                  hand curve channels back to the board, delete the profiles
                         (pins are kept: unpin them by name)
conflicts                other services that write pwm, TSV: unit  state
config                   the resolved state as key=value
```

| Flag | Default |
| --- | --- |
| `--curve` | `30:25 50:35 65:55 75:75 85:100` |
| `--sensors` | CPU package + GPU core |
| `--channels "ID ID@N"` | **required**: the fans on the curve; `@N` = never below N% |
| `--pin "ID@N"` | with `apply`: pin these first, before any curve change |
| `--hyst` | `3` °C |
| `--delay` | `3` s |
| `--url` | `http://127.0.0.1:11987` (`$CARB_URL`) |

## The curve

`degC:duty%` points, with rising temperatures, non-falling duties and at least
two points. Between points the duty is **linear**, the same calculation as
CoolerControl's `interpolate_profile`. Outside the points it is clamped to the
first or last duty. The hottest watched sensor wins.

```sh
$ ./carbonite.sh simulate --curve "30:25 50:35 65:55 75:75 85:100" 20 57 80 95
20   25%
57   44%
80   88%
95   100%
```

A curve CoolerControl would silently rewrite (for example, a duty that falls
as the temperature rises) is refused, so `simulate` never shows anything
different from what will run.

## Ids

`<first 8 of the device uid>:<name>`, with spaces as `_`, for example
`7bfee7e1:fan3` and `e5345c5f:GPU_Temp`. CoolerControl's uids are stable
across reboots, unlike hwmon indices.

## Notes

- **Pins go first.** `apply --pin` writes the pin before any profile, so if a
  later step fails, the pump is already safe. Only `unpin` removes a pin:
  `apply` and `release` never do.
- **`apply` is the whole list.** A fan that was on the curve and is not listed
  any more goes back to the board, and unused profiles are deleted only after
  that, never while a channel still uses them.
- **Floors** are for fans that stall at low duty. On the test machine the
  radiator fans stopped at 35% and restarted at 40%, so they run at `@45`. Find
  the lowest duty that *starts* them from a standstill, then add a margin.
- **A fan that ignores the curve** (low duty, unchanged RPM) is a DC fan, hub
  or pump on a header in PWM mode. The NCT6687 driver does not expose the mode,
  so change it to DC in the BIOS.
- **Re-applying replaces.** Objects have fixed ids, so a second `apply` updates
  them, and leftover per-sensor graphs from a wider apply are deleted.
- **`release`** sets the channels to CoolerControl's Default profile, which
  restores the board's own `pwm_enable` mode, then deletes the objects. It
  stops before deleting if any channel could not be handed back.
- **Other pwm writers** (`fancontrol`, `fan2go`, `thermal-exhaust-port`,
  `nbfc`) fight CoolerControl. `conflicts`, `apply` and `status` say so.
- Written against coolercontrold **4.3.1**: routes, JSON shapes and validation
  rules were taken from that release's source.

## Tests

```sh
tests/run-all.sh
```

No daemon, no token, no hardware. `tests/fake-coolercontrol` stands in for
`curl` (`$CARB_CURL`) as a small, stateful CoolerControl with 4.3.1's routes and
shapes. It refuses to delete a profile that is still in use, so an engine that
deletes before it reassigns fails a test. `tests/fixture.sh` is its starting state, shared with scomp-link's
front-end test.

## License

MIT
