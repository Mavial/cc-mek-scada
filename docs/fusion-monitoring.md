# Integrated fusion monitoring

The fusion computer reads the reactor Logic Adapter, reactor Port and optional
Laser Amplifier. It sends one snapshot per second to the existing Coordinator.
The Coordinator draws a separate 4x4 Advanced Monitor and, for a one-unit facility,
a generation summary on the Main screen. The seven-wide waste controls remain
in their existing position; the summary occupies the unused area to their right.

This release follows the user's decision to retain current reactor operation.
It reads getters only. Fission automatic control, unit limits, FAC SCRAM and waste
settings retain their existing meaning. Fusion has no control buttons or automatic
dispatch in this release, and its output is not fed into the fission controller.

## Hardware

- Separate Advanced Computer next to the fusion equipment (commissioned as ID 9).
- Wired modem/cable network sharing the Fusion Reactor Logic Adapter, Fusion
  Reactor Port and optional Laser Amplifier with that computer.
- Ender Modem on that computer, plus the Coordinator's configured wireless modem.
- Separate 4x4 Advanced Monitor on the Coordinator's wired monitor network.
  Share its modem and leave it unassigned in the stock SCADA configurator.
- Keep both computers and the equipment loaded while monitoring.

The minimum display terminal is 79x52 characters at text scale 0.5, matching a
4x4 monitor in the installed CC:Tweaked 1.120.2. Main 7x4 and Flow 7x3 remain
supported for the existing single fission unit.

## Installation

Download this fork's `install-fusion.lua` to `/install-fusion.lua` on both computers.
Use the same published revision on each. This installer targets the user's
Coordinator 1.10.1 with the previously installed seven-wide patch; it checks the
exact original/patched source hashes before replacing the two Coordinator files.
It accepts both unminified source and the existing minified deployed files.

On the **fusion computer**:

```text
cd /
install-fusion check agent
install-fusion agent
fusion/configure agent
```

Select `fusionReactorLogicAdapter_0`, `fusionReactorPort_0`, `laserAmplifier_0`
and the Ender Modem. Enter the same authentication key used by the existing SCADA
network, or leave it blank if authentication is disabled there. Leave the fusion
telemetry channel at **16245**. The wizard stores these settings locally in
`/fusion/settings.json`.

Run `startup`. The terminal should show the computer ID, channel, reactor status
and generation. It transmits without needing the Coordinator installed yet.
It resumes automatically on boot through its new `/startup.lua`.

On the **Coordinator**, hold Ctrl+T to exit its application before installation:

```text
cd /
install-fusion check coordinator
install-fusion coordinator
fusion/configure coordinator
```

Choose the new 4x4 screen, enter fusion computer ID **9**, and keep channel
**16245**. Existing Main/Flow/Unit monitors are excluded from the list. The wizard
identifies candidate monitors on-screen. Run `startup` to resume SCADA.
The existing Supervisor, PLC and RTU need no update.

## Readings and checks

The detail screen shows fusion output, fission turbine output and their sum,
plasma/casing temperatures, fuel tanks, injection setting, reactor energy buffer,
laser stored energy/minimum threshold, Hohlraum charge and laser redstone mode.
Use the machine GUIs to confirm these readings on first installation.

Mekanism energy getters return joules. The Coordinator uses its existing energy
and temperature units/conversion; FE conversion is the existing factor 0.4.
The fusion computer terminal uses that same FE factor. The combined figure sums
generator outputs; Matrix input includes other sources and is a different metric.
If SCADA's turbine data is unavailable, the fission contribution and total show
`--`. This release assumes the facility's SCADA turbine entries are fission-fed;
do not include a fusion-powered turbine there and also count the same output here.

Premixed D-T operation legitimately has empty separate deuterium/tritium tanks.
The injection setting applies to separate D/T feed operation; changing it is not
a premixed-fuel throttle. Laser threshold reached is an energy observation, not
a promise that ignition will succeed. The Hohlraum component is parsed only for
the known single fusion-fuel tank; unknown charge formats show charge unknown.

Snapshots expire after five seconds. `NO LIVE DATA` hides stale fusion readings.
A getter failure shows `PARTIAL DATA` or `READ ERROR`, with unknown values shown
as `--`. Reconnecting peripherals/modems/screens resumes monitoring automatically.

The dedicated telemetry protocol (97) and channel bypass fission command handling.
The receiver filters the configured source computer, schema, sequence, reboot
session, timestamps, types and finite numeric values. It uses the existing SCADA
NIC and header authentication when enabled; this extension does not change the
upstream network's cryptography or add a new trust/security boundary.

## Undo and interrupted installations

Stop the application first. On each corresponding computer:

```text
install-fusion undo agent
install-fusion undo coordinator
```

Run only that computer's role. The installer restores exact pre-install files,
removes only files it added, and preserves `/fusion/settings.json` plus existing
SCADA configuration. A modified installed file or damaged needed backup causes
undo to refuse before touching live files.

If installation was interrupted, run `install-fusion recover agent` or
`install-fusion recover coordinator`, then repeat installation. Backups and the
journal live under `/.scada-fusion-1/<role>`; retain them until undo is complete.
The installer stages and verifies all files before modifying a live application.

## Local validation

Run `python tools/build-fusion-installer.py`, then `python tests/fusion/regression.py`
with `lupa` (Lua 5.2) installed. Pillow optionally creates screen previews.
The suite uses the actual server commissioning readings, getter whitelist,
native SCADA NIC/authenticated frames, native graphics/pubsub/touch handling,
installed agent boot, and a fault-injecting ComputerCraft filesystem.
It checks stale/reordered/malformed data, unchanged disabled layouts, protected
existing panels, display fit, boot dependencies, and recovery before/after every
installation filesystem mutation. Host APIs are simulated; actual Minecraft
enumeration and first commissioning remain in-game checks.
