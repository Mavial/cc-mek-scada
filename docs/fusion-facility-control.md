# Fusion and fission facility control

Status: implementation design and commissioning probe; not an installable control release.

## Delivery contract

Deliver one integrated release with fusion telemetry, a 4x4 Coordinator display,
facility overview, manual operation, and automatic mixed-generation control.
Internal implementation and testing can be incremental; do not release a
telemetry-only substitute for the requested facility controller.

Target: the existing sodium-cooled fission unit plus one air-cooled fusion reactor
using premixed D-T fuel, Mekanism/Mekanism Extras tubes and laser ignition. Local
client inspection found Mekanism/Generators 10.7.19.85. Verify server capabilities
and compare numerical readings with machine GUIs during commissioning.

Base: upstream cc2eca60ac13f43a3f2af86d5f361bb15f5248f9. Preserve the validated
Main 7x4, Flow 7x3, and Fission Unit 4x4 layouts. Add a separate Fusion 4x4 display
to the Coordinator; fusion is not represented as a fission unit merely to reuse
the existing burn allocator.

## Selected operating policy

Keep fission at a configurable minimum for waste production; fusion covers the
remaining demand. A configured minimum is an operating request, never an override
of fission readiness, fuel restrictions, coolant protection or the unit ceiling.
When an interlock prevents the minimum, display the unmet waste-production goal.

The minimum's value is a commissioning setting in the SCADA UI. No particular
value is required to implement this policy. Other policies may be selected in
the UI, but are not prerequisites for the selected policy.

Matrix charge and discharge determine the power demand. An explicit recharge
budget adds generation when charge is below the selected band. Account for
fission turbine output, fusion output, other incoming power, and the Matrix's
input/output restrictions. Matrix inflow is a storage measurement, not another
generator: never add it to the generator total. Startup energy is a load.

Premixed D-T fuel bypasses the reactor injection-rate limit. Do not claim a
continuously adjustable fusion setpoint without a demonstrated fuel-metering
actuator. The initial full controller can dispatch fusion in sustained runs using
charge hysteresis, minimum run/rest times, output-capacity checks and startup
reserve. A minimum-off timer cannot block an emergency shutdown.

Whether fission can rise above its waste minimum on fusion failure is a visible
UI policy. It must remain below the configured and effective fission limits.
Unserved demand is an explicit state; it is not permission to exceed capacity.

## Control ownership

The Supervisor owns facility demand and dispatch. A local fusion controller owns
actuation and the startup sequence. Use a module with a small interface for the
local controller: observe a timestamped snapshot, accept a bounded operation
lease, and return status. Local hardware adapters implement fuel gating,
Hohlraum loading, and laser firing; the Supervisor does not operate them directly.

The local controller must have an independent periodic update path. Polling a
status register must not be what keeps its timeout checks running. A lease expires
when supervisory control becomes stale; commands carry an identity/sequence and
an acknowledgement. Acknowledged receipt is distinct from confirmed physical
completion. Where an output can remain latched on a crashed computer, use an
appropriate hardware interlock/watchdog and verify its actual behavior.

Keep existing fission PLC protection and unit limits intact. Integration through
shared definitions may require installing a matching common-library version on
all network applications, including the fission PLC, without changing its reactor
protection implementation.

## Fusion lifecycle

States: disabled, verifying, preparing fuel, loading Hohlraum, charging laser,
igniting, confirming reaction, running, stopping, cooling/resting, and latched
fault. Each operation has a bounded timeout and feedback from the relevant
peripheral. Do not infer successful ignition from the command acknowledgement.

Stopping cuts all configured fuel routes and prevents ignition. It verifies the
reaction ceases while continuing to report stored heat and residual generation.
Do not report zero power as soon as fuel is cut: the hot casing continues to
generate electricity while cooling. Stopping a tube's upstream source may leave
enough downstream fuel to continue burning; characterize that delay or locate
the cutoff close to the reactor.

Cold restart requires a sufficiently filled Hohlraum and sufficient laser energy.
Do not treat a nonempty Hohlraum slot as proof that it is charged. If exposed
readings cannot establish its charge, require a verified loader that only supplies
charged items and confirm ignition using isIgnited. A bounded failed attempt
latches a fault instead of spending startup energy in an unlimited retry loop.

Recovering from server/controller restart reconciles actual reactor, fuel gate,
loader, and laser state. It must not resume an old ignition command. Manual
operation also uses these interlocks. Chunk loading and actuator power supply
must cover the whole controlled chain for autonomous operation.

## Configuration and displays

Runtime settings live in the SCADA UI: fission minimum and maximum, charge band,
fusion participation, minimum run/rest times, startup reserve, recharge budget,
fallback policy, retry/timeout limits and control enable. Validate ranges and
display a reason when a configuration cannot operate on detected hardware.

Hardware settings map peripheral names, output side/control polarity, all fuel
routes, fuel buffer, Hohlraum source/loader, laser amplifier and Matrix. Detect
capabilities before permitting the corresponding control operation.

Fusion screen: connection/freshness, actual reaction state, requested operation,
temperatures, generation, buffer, fuel availability, startup readiness, lifecycle
state, and explicit fault reason. Include manual Start/Stop, Auto, and Reset with
command feedback. The main screen shows combined generation, allocation and
unserved demand. FAC SCRAM includes a fusion fuel cutoff with clear feedback;
STOP ends automatic dispatch using documented source-specific behavior.

## Verification required before installation

- End-to-end synthetic RTU/Supervisor/Coordinator data and command flow.
- The local controller's timeout logic without incoming polls or commands.
- Load steps, charge extremes, Matrix input saturation and external generation.
- Fission minimum above available capacity, zero minimum, and critical interlocks.
- Premixed fuel ignoring injection rate and delayed cutoff through buffered tubes.
- Thermal generation continuing after the reaction ends.
- Missing fuel, low startup reserve, absent/uncharged Hohlraum, and failed laser.
- Dropped/duplicated/stale commands, lost acknowledgements and reordered telemetry.
- Disconnects, peripheral detachment, computer restart and server restart in each state.
- Bounded retry behavior and operator reset of latched faults.
- No uncontrolled fission demand following fusion loss or delayed startup.
- Existing fission PLC protection behavior and seven/eight-wide layouts.
- Recovery-capable installer, preserved configuration, matching versions and rollback.
- Final in-game capability, energy-unit, actuator, cutoff, ignition and load-step checks.

The read-only tools/fusion-probe.lua collects server-side peripheral capabilities
and current readings. It writes a local report but has no reactor-control calls.
This is evidence collection for the complete release, not a partial controller.

If Pastebin report transfer fails, `tools/fusion-report-upload.lua` uploads the
existing `fusion-probe.txt` to paste.rs and prints the retrieval link. It checks
the report format, rejects partial uploads, and displays connection errors.
The uploader reads the saved report only; it does not access reactor peripherals.
