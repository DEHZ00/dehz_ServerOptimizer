# Dehz_ServerOptimizer

A server-side performance diagnostic and cleanup suite for FiveM, by Dehz Development.

It does two jobs:

1. **Tells you why your server is running badly** — configuration audit, hitch detection with context snapshots, static analysis of every installed resource, state bag write monitoring, network and entity health.
2. **Cleans up the entity garbage causing part of it** — a sweeper with three separate safety catches, ten protection layers, and dry-run as the shipped default.

Everything destructive is opt-in. Nothing is deleted until you deliberately turn off three separate switches.

---

## Requirements

| | |
|---|---|
| **FXServer** | Any current build. Capabilities are probed at start and anything unavailable is reported, not faked. |
| **OneSync** | **Required for the entity features.** Without OneSync there is no server-side entity list, so the Entity Sweeper, Distance Culling and entity counts cannot function. The resource says so at start rather than reporting zero entities. |
| **Framework** | None. ESX Legacy and QBCore are optional and additive only. |
| **oxmysql** | Optional. Auto-detected. Needed for owned-vehicle plate protection and long-term history. |
| **ox_lib** | Optional. Auto-detected. Used for notifications only. |

`ox_inventory` and `ox_target` are **not** used or required.

## Install

1. Drop the folder into your resources directory.
2. `ensure Dehz_ServerOptimizer` in `server.cfg`.
3. Grant yourself access: `add_ace group.admin dehz.optimizer allow`
4. Open the dashboard in game with `/serveropt`.
5. Read `config.lua`. It is written for server owners and it is the only file you need to touch.

---

## The three safety catches

The Entity Sweeper touches nothing until **all three** of these are changed:

```lua
Config.Mode              = 'monitor'   -- must become 'active'
Config.Sweeper.dryRun    = true        -- must become false
Config.Sweeper.action    = 'report'    -- must become 'orphan' or 'delete'
```

`Config.Mode = 'monitor'` overrides everything. A module can never act in monitor mode regardless of its own settings.

### The three sweeper actions

- **`report`** — runs every check, logs exactly what it would have done and why (model, coordinates, age, population type, creating resource, plate), and touches nothing.
- **`orphan`** — sets the engine's own `SetEntityOrphanMode` to `DeleteOnOwnerDisconnect`. The **server** cleans the entity up naturally when its original owner leaves. This resource deletes nothing. It is reversible, correct by construction, and for most servers it is enough. **This is the recommended first real step.**
- **`delete`** — calls `DeleteEntity`. Last resort.

### Protection layers

An entity matching **any** of these is skipped unconditionally, regardless of age, distance or occupancy:

| Layer | Notes |
|---|---|
| `Entity(e).state.dehz_protected = true` | The primary integration point for other resources. |
| Foreign state keys | Configurable list of other resources' own persistence flags. |
| Orphan mode `KeepEntity` | Another resource explicitly asked the server to keep it. |
| Attached entities | Trailers, props carried by peds. |
| Model whitelist | Names or hashes. |
| **Creating-resource whitelist** | Matched against `GetEntityScript`. Protects everything a named resource created, with no cooperation needed from it. |
| Routing bucket | Non-zero buckets protected by default (instanced content), plus an explicit list. |
| Coordinate zones | Dealerships, garages, impounds, job spawns, prop-heavy MLO exteriors. |
| Owned-vehicle plates | ESX `owned_vehicles` + `rented_vehicles`, QBCore `player_vehicles` including `fakeplate`. Table and column names are **config values**, never hardcoded. |
| Unsynced origin `(0,0,0)` | An entity that has not synced yet reports the origin, which looks maximally far from every player. This is the most likely way a naive sweeper deletes something it shouldn't. |

Plus, before an entity is even considered: minimum age tracked by us, minimum distance from the nearest player, no network owner, allowed population type, no ped in **any** seat, and **N consecutive failed sweeps** (`graceSweeps`) so a momentary streaming gap can never cause a deletion.

If the plate lookup fails and `Config.Sweeper.requirePlateLookup` is true, the sweeper **refuses to run in live mode**. A broken database query never silently widens what may be deleted.

---

## What this resource is honest about

This is the part that matters. Everything below is a real, verified limitation.

### The server main thread runs at 20 ticks per second

A FiveM **server** frame is 50 ms, not 16 ms. Resource ticks run from the main thread's timer, so a `Wait(0)` loop on the server resumes at most once every 50 ms. That has consequences the rest of the market ignores:

- Hitch thresholds borrowed from client intuition are meaningless here. Ours ship as **clearly-marked uncalibrated placeholders** and say so in config and in the UI.
- A pure Lua timer cannot see a stall shorter than 50 ms, and it is completely blind to the **sync thread** (120 Hz) and **network thread** (100 Hz) — and the sync thread is where OneSync entity work actually happens.

So the hitch detector uses **three sources**, best available first:

1. **`/perf`** — the server's own Prometheus metrics endpoint, giving real measured `tickTime` histograms for `svMain`, `svNetwork` and `svSync`. Percentiles come from the histogram buckets.
2. **Console** — FXServer prints its own hitch warnings (main and network above 150 ms, sync above 100 ms). We read them with `RegisterConsoleListener`. This is the only way to see sync-thread stalls at all.
3. **Timer** — our own thread, filling the 50–150 ms band the engine does not report. It stands down above 150 ms when the console source is active, because the engine's figure is authoritative.

The dashboard shows which sources are live. Percentiles over windows longer than 90 seconds are computed from per-second maxima and are **labelled "approx"**.

### `Wait(0)` counting is deliberately weighted low

On the server a `Wait(0)` loop is a 50 ms tick, and a `Wait(0)` loop that does nothing is cheaper than a `Wait(500)` loop that runs an SQL query. Counting them ranks code style, not cost. It is reported, but it barely moves the risk score, and the config comment says why.

### Risk scores are estimates, not measurements

Nothing on a FiveM server exposes live per-resource CPU cost. The component that measures it on the client (`citizen-devtools`, i.e. resmon) is client-only by construction.

The Resource Analyzer's risk score is an **estimate from static code patterns**. It is labelled that way in the UI, in the exported report, and in the webhook. It is never presented as measured milliseconds.

**However** — see the profiler below.

### The optional profiler *does* produce real measured numbers

FXServer's built-in profiler brackets every resource tick and every event handler with microsecond timestamps, and its `profiler record` / `profiler saveJSON` commands are reachable from a script. So real per-resource timing **is** obtainable on the server, as a short sampling session.

`Config.Profiler` ships **disabled**, and when enabled it is never automatic — it only runs when an admin asks. Understand the cost before you use it:

- While recording, the server does extra work for every resource tick and event.
- Decoding the resulting JSON is **one unavoidable blocking step**. We measure it, log it, and warn you if it exceeded 120 ms (i.e. if it showed up as a hitch itself). There is a hard file-size cap.
- It is a sample of a few seconds, not a live monitor.

Results are shown in a separate panel labelled **measured**, visually distinct from the estimated ranking.

You can also do this by hand without this resource: `profiler record 60`, then `profiler saveJSON <path>`, then read the Chrome-trace JSON. The module just automates it with guard rails.

### The state bag monitor reports spam. It cannot prevent it.

The FiveM state bag change handler documentation says it directly: *"At this time, the change handler can't opt to reject changes."* There is no throttle, no rejection, no rate limit available to a resource. This module counts writes per key, per bag scope, and in aggregate over a rolling window, and flags the noisy ones. That is all it can do.

Related: `sv_stateBagStrictMode` (audited by Module 3) rejects client writes for entities they don't own, which is the only real lever that exists.

### Distance culling is deprecated by Cfx.re

`SetEntityDistanceCullingRadius` and `SetPlayerCullingRadius` both carry this official warning:

> *"Culling natives are deprecated and have known, unfixable issues"*

Module 2 therefore ships **disabled** and requires a **second explicit opt-in** (`Config.Culling.acknowledgeDeprecated = true`) before it will run at all. The supported route to the same outcome is the `onesync_distanceCulling` and `onesync_distanceCullVehicles` convars, which the Config Auditor reports on. Use those first.

### Escrowed resources cannot be *read* — but they are still measured

Escrow encrypts **Lua, YFT, YDD and YDR** files. It does **not** encrypt `fxmanifest.lua`, YTD textures, YMAP/YBN, JavaScript, or anything listed under `escrow_ignore`. So a paid script's Lua is opaque to the analyzer, while a JS-based resource is fully readable.

We detect escrow (a `.fxap` file in the resource root, an `escrow_ignore` manifest key, or content that reads back as binary), mark the resource **`unscannable`**, and list it **separately** so the risk ranking is not misleading. Escrowed resources are never scored as clean.

**Escrow hides source, not behaviour.** Every unreadable resource still gets measured on four runtime signals that no amount of encryption affects:

| Signal | Where it comes from |
|---|---|
| **Entities created** | `GetEntityScript` on every indexed entity |
| **Script errors** | `SCRIPT ERROR` lines on that resource's console channel |
| **Console line volume** | its `script:<name>` channel |
| **Stream weight** | file sizes on disk — encrypted files still have a size |

A resource whose code you cannot read, but which created 192 world entities and threw 31 script errors in the last hour, is a finding you can act on. That is what the **"source unreadable — measured by behaviour instead"** table shows, and the same figures appear as columns on the main ranking so escrowed and open resources sort side by side.

Static analysis is one of nine modules. The other eight — sweeper, entity attribution, hitch detection and its context snapshots, config audit, state bag monitor, network monitor, reporting, exports — are unaffected by escrow entirely.

### Stream weight *is* measurable

The FXServer Lua runtime ships a sandboxed `io` library that includes `io.readdir`. Where it is available we walk each resource's real file tree and report streamable asset count and bytes. Where it is not, we say so and fall back to manifest-declared files only, marking those scans **"manifest only"**. We never claim to have measured something we couldn't.

### Server-side deletion does not always stick

Clients can re-create an entity the server deleted in certain ownership states ([citizenfx/fivem#2256](https://github.com/citizenfx/fivem/issues/2256)). When `verifyDeletions` is on, the next sweep checks whether entities really went away and reports a resurrection count instead of assuming success.

### Three convars cannot be changed at runtime by anything

`onesync` is an internal ConVar, and `onesync_population` and `sv_enforceGameBuild` are read-only. The engine rejects `SetConvar` on all three. So `Config.Auditor.allowAutoApply` — which ships **false** — can never apply them. The dashboard marks those findings **"server.cfg only"**.

### Convars named in older guides that do not exist

The audit table was built against the FXServer source, not folklore. These are **not real convars** and are not audited:

| Commonly repeated | Reality |
|---|---|
| `game_enableNetworkedSounds` | Does not exist. The real one is `sv_enableNetworkedSounds` (default `true`). |
| `game_enableNetworkedPhoneExplosions` | Does not exist. The real one is `sv_enableNetworkedPhoneExplosions`, and it already defaults to `false`. |
| `sv_useDirectListing` | Does not exist. |
| `sv_endpointPrivacy` | Exists but has been **removed in function**. Setting it prints a deprecation warning. We report it as a line to delete, not a setting to change. |

If a convar in the audit table doesn't exist on your build, it is skipped silently and listed under "not present on this build" — never reported as a false finding.

---

## Deliberately not built

These were considered and excluded. If any becomes possible on a future build we will say so rather than quietly shipping it.

- **Global event interception / "event spam protection."** Each resource has its own Lua runtime, so another resource's `TriggerEvent` calls cannot be hooked from here. The state bag monitor and the static analyzer are the only real signals, and that is what we ship.
- **Continuous per-resource CPU monitoring.** No native exposes it. The opt-in profiler is a short sample, not a monitor, and it is labelled as such. See above. (The profiler does measure escrowed resources fine — it times the runtime, not the source.)
- **Anything claiming to raise server tick rate.** The main thread's 20 Hz timer is set by the engine.
- **Client FPS features.** That is `Dehz_Optimizer`'s scope.
- **Automatic convar writing by default.** `allowAutoApply` ships false, and cannot touch the three convars that matter most anyway.
- **Displaying or exporting other resources' source code.** The analyzer outputs a file path, a line number and a pattern name. Never a line of code. This is not configurable.
- **Framework-gated features.** Nothing here becomes unavailable on standalone.
- **Hardcoded framework table or column names.** All of them are config values with documented, verified defaults.

---

## Modules

| # | Module | Runs |
|---|---|---|
| 0 | Entity index | Every 15 s, staggered across frames. Feeds everything else so nothing enumerates the pool twice. |
| 1 | Entity Sweeper | Every 5 min, after a startup grace period, only above a player threshold. |
| 2 | Distance Culling | Disabled. Deprecated natives, double opt-in. |
| 3 | Config Auditor | At start, on demand, and on convar change (event-driven). |
| 4 | Hitch Detector | Continuous. Three sources. |
| 5 | Resource Analyzer | At start and on demand only. Never on a loop. |
| 6 | State Bag Monitor | Continuous, observe-only. |
| 7 | Network & Player Monitor | Every 30 s. Real per-player packet loss and RTT via `GetPlayerPeerStatistics`. |
| 8 | NUI Dashboard | Only while open. Zero cost while closed. |
| 9 | Reporting | Per-module Discord webhooks, txAdmin-shaped console output, exportable health report, optional oxmysql history. |
| 10 | Exports API | See below. |

### Health score

A weighted average, documented so you can argue with it:

```
config audit  30%   100 - (critical x 18 + warning x 7 + info x 1)
hitches       30%   100 - (severe x 20 + major x 5)  over the last hour
entity load   20%   scales down above 40 entities per player
resources     20%   scales down with the top resource's estimated risk
```

### Exports

```lua
exports['Dehz_ServerOptimizer']:getHealthScore()          -- score, components
exports['Dehz_ServerOptimizer']:getMetrics()
exports['Dehz_ServerOptimizer']:getHitchHistory(count)
exports['Dehz_ServerOptimizer']:getHitchPercentiles(windowMs)
exports['Dehz_ServerOptimizer']:getEntityCounts()
exports['Dehz_ServerOptimizer']:getEntityBreakdown()
exports['Dehz_ServerOptimizer']:getAuditFindings()
exports['Dehz_ServerOptimizer']:getResourceReport()
exports['Dehz_ServerOptimizer']:getStateBagReport()
exports['Dehz_ServerOptimizer']:getNetworkReport()
exports['Dehz_ServerOptimizer']:getSweepHistory(count)
exports['Dehz_ServerOptimizer']:forceSweep(category, dryRun)
exports['Dehz_ServerOptimizer']:protectEntity(entity)
exports['Dehz_ServerOptimizer']:unprotectEntity(entity)
exports['Dehz_ServerOptimizer']:isEntityProtected(entity)   -- boolean, reason
exports['Dehz_ServerOptimizer']:protectPlate(plate)
exports['Dehz_ServerOptimizer']:unprotectPlate(plate)
exports['Dehz_ServerOptimizer']:isPlateProtected(plate)
exports['Dehz_ServerOptimizer']:isDryRun()
exports['Dehz_ServerOptimizer']:getMode()
exports['Dehz_ServerOptimizer']:getFramework()
exports['Dehz_ServerOptimizer']:getCapabilities()
exports['Dehz_ServerOptimizer']:getPlateProtectionStatus()
exports['Dehz_ServerOptimizer']:buildHealthReport()
exports['Dehz_ServerOptimizer']:exportHealthReport(actor)
exports['Dehz_ServerOptimizer']:runConfigAudit()
exports['Dehz_ServerOptimizer']:runResourceAnalysis()
exports['Dehz_ServerOptimizer']:getProfileReport()
exports['Dehz_ServerOptimizer']:getLogs(count, module, level)
exports['Dehz_ServerOptimizer']:isAdmin(source)
```

The simplest integration is one line in your own resource:

```lua
exports['Dehz_ServerOptimizer']:protectEntity(vehicle)
```

or, with no dependency on this resource at all:

```lua
Entity(vehicle).state.dehz_protected = true
```

### Framework bridge

One file: `server/bridge/framework.lua`. No core module calls a framework function directly. Adding a fourth framework means touching only that file.

- `isAdmin(source)` — **ACE first, and ACE always wins.** Only if ACE denies does the framework's own permission system get consulted.
- `notify(source, message, type)` — ox_lib, then the framework's notification, then plain chat. Never errors if none exist.
- `getPlayerLabel(source)` — character name where the framework has one, name plus license otherwise.
- `getProtectedPlates()` — cached, refreshed on a timer, never queried per entity or per sweep tick. Standalone returns empty.

Table and column names are validated against `^[A-Za-z0-9_]+$` before being used in a query.

---

## Performance

- The hitch detector's timer thread is the only tight loop, and it does nothing but read a timer and compare.
- Every other recurring task runs on a long configurable interval and yields with a per-frame budget: entity scanning, sweeping, culling, the analyzer's directory walk, its line scanner, and the profiler's aggregation all stagger across frames.
- The dashboard costs nothing while closed.
- The config auditor is event-driven via `AddConvarChangeListener` rather than polling.

One honest note on the "0.00ms" claim you will see on competing resources: that is a **client** resmon figure. The server has no per-resource millisecond readout at all — which is exactly why continuous per-resource monitoring is on the "not built" list. What this resource can promise is bounded work per tick and no busy-waiting.

## Notes for developers

- Everything a buyer needs to tune lives in `config.lua`. It is the only commented file, and it is written in plain English for server owners.
- There are **two** globals: `Config`, and `Dehz`, which is the module registry. Lua files inside one resource share a state but not their locals, so cross-file wiring needs one shared table; the alternative is per-call export indirection on every internal call, which costs more than it is worth. Everything else in every file is local.
- Layout:

```
config.lua                  the only file an owner edits
shared/constants.lua        enums shared with the client bridge
server/core/                log, util, state, capability probe, boot
server/bridge/              the single framework bridge
server/data/                convar audit table, analyzer pattern table
server/modules/             the nine server modules
server/report/              webhooks, database, health report export
server/api/exports.lua      the exports API
server/nui/server.lua       admin gate, payload building, action audit log
client/nui.lua              NUI bridge only - there is no other client code
web/                        the dashboard
```

## Troubleshooting

**"OneSync is off"** — the entity features cannot work. `set onesync on` in `server.cfg`.

**Plate protection says "lookup failed"** — open `config.lua`, find `Config.FrameworkOptions`, and check the table and column names against your actual database. Current qb-core does **not** ship a `player_vehicles` table itself; it comes from qb-garages or qb-vehicleshop.

**A sweep hit the cap** — `maxDeletionsPerSweep` exists to catch a misconfiguration. Hitting it almost always means a category rule is too loose, not that your server is that dirty. Read the dry-run output before raising it.

**The dashboard does not open** — you need the ACE: `add_ace group.admin dehz.optimizer allow`. Players without permission get no response at all, by design.

**Everything says "off" in the capability strip** — you are on an older FXServer build. Each feature degrades to nothing rather than pretending to work.
