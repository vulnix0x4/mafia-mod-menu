# MAFIA — learnings and research notes

Scope: client-side research only. No server code, no remote hooks. Use in private
servers or with explicit permission. The game's own rules prohibit exploiting;
treat this as an authorized local testing project.

## Game identity

| Field | Value |
|---|---|
| Name | **MAFIA** |
| Studio | Topline Studios |
| Place ID | `113232329524315` |
| URL | https://www.roblox.com/games/113232329524315/MAFIA |
| Genre | Social deduction, first-person night phase |
| Roles | 16 (Town, Mafia, Veil, Neutral) |

## Mechanics (from the official community wiki)

- Three main factions plus neutrals:
  - **Town** — uninformed majority. Wins by eliminating the Mafia.
  - **Mafia** — informed evil minority. Wins at numerical parity with remaining citizens.
  - **Veil** — informed chaos minority. Wins by filling a corruption bar to 100%.
  - **Neutral** — own win conditions (e.g. Jester, Phantom, Bodyguard).
- Rounds alternate **Night** and **Day**:
  - Night: Mafia hunt their target in first person; Doctor/other roles act.
  - Day: discussion, accusations, and a vote to eliminate a suspect.
- Known roles include Civilian, Detainer, Detective, Doctor, Janitor, Judge,
  Suppressor, Vigilante, Bodyguard, Jester, Phantom, Snow Spirit, Mafia, Witch,
  Harbinger, Mirage, Poisoner, Saboteur.
- Latest documented version at time of research: **2.4.0** (Halloween 2026).

Sources:

- https://wiki.toplinestudios.gg/wiki/Main_Page
- https://wiki.toplinestudios.gg/wiki/Gameplay
- https://wiki.toplinestudios.gg/wiki/Mafia_(the_game)
- https://robloxmafia.fandom.com/wiki/Mafia_Wiki

## Live recon (2026-11-01)

The client has been inspected read-only. Full dump: `docs/RECON.md`.

- Live place `83705601973004`, universe `7497471789` (`game.Name = "Ugc"`).
  The wiki's `113232329524315` is the experience entry point; rounds run in a
  sub-place of the same universe.
- Own role: `PlayerGui.RoleDisplay.Wrapper.Text` (`Your role is: Harbinger`).
- Phase, objective, and action: `PlayerGui.Tips...Content.Title/Objective/Action`
  (e.g. `DISCUSSION — HARBINGER`).
- Corruption: `PlayerGui.NoirApp...Label` (`VEIL CORRUPTION 0%`).
- Players remaining: `PlayerGui.NoirApp` (`PLAYERS REMAINING: 11`).
- Other players: `DisguiseName` and `Dead` attributes; `Downed`, `Ragdolled`,
  and `DeathPosed` on the character. Real roles are **not** replicated.
- `ReplicatedStorage.RoleNetworks` has one folder per role; `ServiceNetworks`
  has 45 service folders. Remote names are documented, but no remotes have
  been called.
- `ReplicatedStorage.GameFlowLogRemote` streams phase boundaries, body/death
  events, and system messages client-side. See `docs/FLOWLOG.md`.

## Still unknown

1. **Remote payloads** — arguments and server validation for night actions,
   voting, and interactions.
2. **Anti-cheat** — remote rate limits, sanity checks, and whether client
   teleport/speed changes are detected.
3. **Voting flow** — how the day vote is submitted and whether it is validated
   server-side.
4. **Map structure** — lobby vs. round map, spawn points, interaction parts.
5. **Spectator path** — whether dead clients receive the full role list.

## Role data boundary

The client receives **only its own role**. There is no global role table in
`ReplicatedStorage`, no role attribute on `Player`/`Character`, and no role
column in `playersList`. Other players expose disguise, health, position, and
dead/downed state only.

Read-only self-queries confirm the boundary:

| Call | Result as Vigilante (Town) |
|---|---|
| `roleService.role:InvokeServer()` | `{ "vigilante" }` |
| `teamService.teamMembers:InvokeServer()` | `{}` |
| `highlightsService.highlights:InvokeServer()` | `{ {} }` |

The architecture is **per-role getters**, not a broadcast table:

- `RoleNetworks.mafia.getTeamMembers` / `teamMembers`, and the same pair under
  `witch` and `bodyguard`, return team data only for that role.
- `pallbearerService.claimableRoles` backs a client component whose `_property`
  is `nil` unless the Pallbearer perk is equipped.
- `detective.investigationInfo`, `judge.judgePlayers`, and
  `judge.observedBallots` return role-adjacent results only for those roles.
- `gameService.revealRoles` is a real `RemoteEvent`, but no role table is cached
  client-side between calls.

Public reveal channels that **do** carry role information:

- `gameService.revealRoles`
- `gameService.playDeathCutscene`
- `medalService.clip` (kill/medal clips)
- `announcementService.show`
- `endService.endCutscene`
- `medalController.publiclyRevealedRoles = { bodyguard, jester, mafia, witch }`
- `medalController.highValueRoles = { doctor, vigilante, detective }`
- `medalController.fallbackMafiaTeamRoles = { mafia, witch }`

`chatService.onSystemMessage` relays **player chat**, not system messages. A
message like "X is the mafia" is a claim, not a reveal, so it is not parsed as
proof.

A live body-found payload was captured:

```text
playBodyFoundCutscene = { totalDuration = 6, bodyFinder = <UserId>, bodyCFrame = {...} }
```

No victim or role field. Body cutscenes are not a role reveal.

Game highlights not named `teammate*` are ability/target markers:
`managedHighlight`, `JesterApparition`, etc. Only `teammate*` highlights count as
team info; the roles module ignores the rest.

The **roles module** listens to the reveal channels above and records confirmed
roles per player. `_G.__mafiaState.Players()` exposes those entries to scripts
and probes. Team tags come from game highlights or from the manual no-argument
team self-query. Everything else remains a claim or an inference. The focused
v0.2 menu does not render dedicated ROLES / PLAYERS tabs.

- A universal "show every hidden role" view would require a server-side leak or
  an invalid remote call. Both are out of scope and are the traffic anti-cheat
  is most likely to flag.
- Selecting or changing a role is server-authoritative. Forging those remotes is
  out of scope.
- The **claims module** remains the honest notebook for guesses and deductions
  (`_G.__mafiaClaims`); it no longer has a menu tab.

## ESP teammate colors (2026-11-02)

The live client exposes team membership through the no-argument
`teamService.teamMembers` RemoteFunction:

```text
{ { members = { mafia = { <UserId>, ... }, witch = { ... } }, team = "mafia" } }
```

`teamMembers` is a self-query: it takes no player argument and is the same call
the game client makes to build its own team view. The role-network
`mafia.getTeamMembers` call errors when invoked with no arguments, but
`mafia.teamMembers` returns the category table
(`{ bodyguards = {}, mafia = { <UserId> }, witches = {} }`). The roles module now
prefers `teamMembers` over `getTeamMembers`; the service-level
`teamService.teamMembers` call returns the same membership under
`members.mafia` / `members.witch`.

`esp.lua` reads `_G.__mafiaRoles.Team()`, colors those UserIds red, and leaves
everyone else green. It also treats any confirmed Mafia/Witch reveal as a
teammate when the local role is Mafia/Witch, so a dead or publicly revealed
teammate is red even if the team query omitted them. `Auto team scan` runs once
per team role (with two empty-team retries), and `Refresh teammates` reruns it
manually. The ESP highlight fill, outline, and name tag all use the teammate
red; the fake-entry live test produced `outline = 1, 0.298, 0.376` and reverted
to green when the entry was removed.

## Harbinger power states (2026-11-01)

`PlayerGui.Tips...Content.Action` is the reliable state source:

| Action text | Meaning |
|---|---|
| `You cannot use your power yet. It unlocks when the Veil parts...` | locked |
| `Press T ...` | ready / usable now |
| `You had a power last night and never used it. Your side needs it.` | missed last night |

The menu parses these into `powerState = locked / ready / missed` and the HUD
shows `power <state>` for Harbinger. `playersList` stays `Enabled = false`
while the power is locked; its role boxes are only templates (`roleBox` with
`Mafia`, player rows `evil`/`regular`) that get populated when usable.
Pressing `T` while locked does nothing and does not focus chat.

## Fullbright vs EMP (2026-11-01)

The first fullbright implementation only set `Brightness`, `Ambient`,
`OutdoorAmbient`, `ClockTime`, and `FogEnd`. It looked disabled during an EMP
because the game drives other lighting properties much harder:

| Property | Observed dark state | Fullbright value |
|---|---|---|
| `Lighting.ExposureCompensation` | `-10` | `0` |
| `Lighting.Brightness` | `0.3` | `2` |
| `Lighting.Ambient` | `(0.078, 0.063, 0.047)` | `(190, 190, 190)` |
| `Lighting.OutdoorAmbient` | `(0, 0, 0)` | `(190, 190, 190)` |
| `Lighting.ClockTime` | `0` | `14` |
| `Lighting.FogEnd` | `50` | `100000` |
| `Lighting.EnvironmentDiffuseScale` | `0.065` | `1` |
| `Lighting.EnvironmentSpecularScale` | `0.696` | `1` |
| `Lighting.GlobalShadows` | `true` | `false` |

Post-processing also matters:

- `Lighting.blur` is a `BlurEffect` and was enabled during EMP.
- `Lighting.DV`, `NV`, `JV`, `GunFlare`, `SaturationCorrection`, etc. are
  `ColorCorrectionEffect`s; only `DV` was enabled in the observed state.
- `EmpAfterimage` and `EmpInk` are full-screen `ScreenGui`s whose image
  transparencies animate during EMP. `Vignette` is a full-screen image.
- `Lighting.stuff` existed as an empty folder; effects may be added at runtime.

Full-screen overlay suspects (all can be opaque black during EMP/transitions):

| Instance | Normal state |
|---|---|
| `Fade.Wrapper` | `BackgroundTransparency = 1`, size `3×3` screens |
| `UI.Fade` | `BackgroundTransparency = 1`, size `1.05×1.05` screens |
| `UI.Grain` | `ImageTransparency = 0.94`, size `7000×5000` px |
| `EmpAfterimage.EmpAfterimage` + `Haze`/`Core` | frame `bgT=1`, images `imgT=1` |
| `EmpInk.EmpInk` + `Ink1..8` | frame `bgT=1`, images `imgT≈0.8` |
| `Vignette.vignette` | image `imgT=1` |
| `nextNightTransition.Root` | **opaque black frame**, `bgT=0`, full screen; `ScreenGui` enabled at night transitions |
| `PuppeteerControlOverlay.Root.Ring.Vignette` | full-screen image, `imgT=0` while the ability is active |
| `Death.Wrapper` | full-screen frame, opaque while dead |

`nextNightTransition` is the strongest candidate for "EMP still black": it is an
opaque full-screen frame that the game enables exactly at night start, which is
when EMP fires. It was not in the original guard list.

The current `visuals.lua` guard has three layers:

1. **Per render frame** (`RunService.RenderStepped` *and*
   `BindToRenderStep("MafiaFullbrightCore", RenderPriority.Last)`):
   re-applies `Brightness`, `Ambient`, `OutdoorAmbient`, `ClockTime`, `FogEnd`,
   `FogStart`, `GlobalShadows`, `ExposureCompensation`,
   `EnvironmentDiffuseScale`, `EnvironmentSpecularScale`; disables the known
   EMP/fade `ScreenGui`s (`Emp`, `EmpAfterimage`, `EmpInk`, `Vignette`, `Fade`,
   `nextNightTransition`); and mutes all post-processing effects
   (`BlurEffect`, `BloomEffect`, `SunRaysEffect`, `DepthOfFieldEffect`,
   `ColorCorrectionEffect`) plus `Atmosphere` density/haze/glare. The effects
   are per-frame because the game can re-enable a dark ColorCorrection between
   the old 0.1 s ticks — this was the remaining "kinda see but not fullbright"
   layer.
2. **Every 0.1 s**: repeats the effect/atmosphere mute as a backup and forces
   transparency/`Visible=false` on all GuiObjects in the known screens and on
   `UI.Fade` / `UI.Grain`.
3. **Generic sweep (every 0.1 s)**: scans every enabled `ScreenGui` and hides
   any visible GuiObject that covers at least 75% of the viewport with
   `BackgroundTransparency <= 0.25` or `ImageTransparency <= 0.25`. This catches
   unnamed/newly-created blackout layers.

Original values are saved once and restored on toggle-off **safely**: negative
exposure is clamped to `0`, blur/DoF are never restored to `true`, and the
EMP/fade screens are never re-enabled. See the post-EMP black-screen section.

Simulated EMP test (dark values + blur + a dark `ColorCorrectionEffect` + opaque
`Fade`/`UI.Fade`/`UI.Grain`/`EmpInk`) was suppressed within one frame. A second
test enabled fullbright during the simulated dark state and then turned it off:
exposure ended at `0`, blur at `false`, `Fade` disabled, screen visible.

If a future EMP still darkens the screen, run `lua/probes/emp_snapshot.lua`
during the dark moment. It prints the current Lighting values, every
post-effect, and every large visible GuiObject with transparency below 0.95 —
that identifies the exact layer still covering the screen.

### Actual EMP capture (EMPW3)

The live watcher caught a real EMP:

```text
TRIGGER exposure -10
DARK  fb=true exposure=-10 bright=2 blur=false
      fade=1 fadeOn=false  inkOn=false  inkT=1
AFTER fb=true exposure=-10 bright=2 blur=false
```

Two conclusions:

1. The ScreenGui guard worked — `Fade` and `EmpInk` were already disabled
   while their animations kept running.
2. `ExposureCompensation = -10` was held by the game; reasserting it every
   0.1 s was not enough. Core lighting now reasserts on `RunService.RenderStepped`
   (every frame), while effects/overlay guards stay on the 0.1 s loop.

The first snapshot also showed `fb=false` once, so the watcher now forces
fullbright back on every polling tick during a test.

### EMP still dark after the per-frame fix (EMPW4)

A real EMP was caught with fullbright already on:

```text
DARK  fb=true exposure=-10 bright=2 blur=false
      fade=1 fadeOn=false inkOn=false inkT=1 inkSize=1253..2432
AFTER fb=true exposure=-10 bright=2 blur=false
```

The EMP/fade screens were suppressed, yet exposure stayed at `-10`, and the
user still saw black. Two separate problems:

1. **`nextNightTransition.Root` was never guarded.** It is an opaque black
   full-screen frame that the game enables at night start; EMP happens at the
   same moment. It is now in the per-frame guard list.
2. **Render order.** `RunService.RenderStepped` can run before game-owned
   `BindToRenderStep` callbacks (camera/character priorities), so the game could
   write `-10` after our reset but before the frame rendered. Core lighting now
   also binds at `RenderPriority.Last` (2000).

Verification (synthetic, live):

- Forced `ExposureCompensation = -10` every frame from a `RenderPriority.Camera`
  callback for 1 s: a probe bound at `RenderPriority.Last` after our guard saw
  `0` on **217/217** frames.
- Enabled `nextNightTransition`: its `ScreenGui` was disabled within the same
  frame.
- Created a fake full-screen black `Frame` in a new `ScreenGui`: the generic
  sweep set `Visible=false` and `bgT=1` within 0.45 s.
- Toggle-off restored the captured pre-fullbright values.

### Generic overlay sweep thresholds

`visuals.lua` hides a GuiObject when all of these hold:

- its `ScreenGui` is enabled and is not `MafiaMenu` / `MafiaESP` / `MafiaHUD`,
- the object is `Visible`,
- its `AbsoluteSize` is at least 75% of the camera viewport on both axes,
- `BackgroundTransparency <= 0.25` or (for images) `ImageTransparency <= 0.25`.

Known game GUIs excluded from the sweep by name are only the toolkit's own.

### Why the render-priority fix was still not enough (EMPW5)

The next EMP showed no overlay at all:

```text
DARK  fb=true exposure=-10 bright=2  ambient=0.745098
      black=0  nnt=false  emp=false  fade=false  ink=false  vig=false
AFTER fb=true exposure=-10 bright=2  ambient=0.745098
```

So the remaining layer was purely `Lighting.ExposureCompensation`. A frame-order
probe explained why our writes lost:

```text
heartbeat -> bind-2000 -> bind-10000 -> renderstepped
```

`RenderStepped` fires **after every `BindToRenderStep` callback**, including
priority 10000. The EMP writer is a render-step/heartbeat loop that runs after
our callback and immediately before the frame is drawn, so it always won the
race.

The fix is to stop racing frames: `visuals.lua` now connects
`Lighting:GetPropertyChangedSignal(key)` for every fullbright-controlled
property (`Brightness`, `Ambient`, `OutdoorAmbient`, `ClockTime`, `FogEnd`,
`FogStart`, `GlobalShadows`, `ExposureCompensation`,
`EnvironmentDiffuseScale`, `EnvironmentSpecularScale`). When the game writes
one, the handler fires synchronously — in whatever phase the write happened —
and snaps it back before rendering. An `applying` flag prevents recursion.
The per-frame loops and `RenderPriority.Last` bind remain as backup.

Live verification with a late `RenderStepped` writer that forced the real EMP
values (`-10`, `0.3`, black ambient) every frame:

```text
[LATE] samples=233 good=233 bad=0 finalExposure=0 finalBright=2
```

### Post-EMP black screen (restore bug)

Turning fullbright off used to restore the values captured when it was enabled.
If it was enabled during an EMP, that snapshot held
`ExposureCompensation = -10`, `BlurEffect.Enabled = true`, and an enabled
`Fade` ScreenGui. Toggling off re-applied all three, leaving the screen black
with no game event to undo it.

Fixes in `visuals.lua`:

- Never restore a negative `ExposureCompensation`; clamp it to `0`.
- Never restore `BlurEffect` / `DepthOfFieldEffect` to `true`.
- Never re-enable `Emp`, `EmpAfterimage`, `EmpInk`, `Vignette`, `Fade`, or
  `nextNightTransition`; leave them disabled and let the game re-enable them.
- Skip restoring fully opaque full-screen overlays (they are blackouts).
- 12 s unstick watchdog: with fullbright off, if exposure stays `<= -2`,
  clear it and lift brightness.
- `API.Repair()` and **SYSTEM → Repair black screen** apply safe visible defaults.

Simulated test: enabled fullbright with `exposure=-10`, `brightness=0.3`,
blur on, and `Fade.Wrapper` at `0` transparency. After toggle-off:
`exposure=0`, `brightness=0.3`, `blur=false`, `Fade` disabled, and the screen
was visible instead of black.

### 2026-11-02 hardening

The live build added a `TeleportScreen` overlay and keeps some effects under
`workspace.CurrentCamera`. The guard now also:

- disables `TeleportScreen` alongside `Emp`, `EmpAfterimage`, `EmpInk`,
  `Vignette`, `Fade`, and `nextNightTransition`;
- mutes `BlurEffect`, `BloomEffect`, `SunRaysEffect`, `DepthOfFieldEffect`,
  and `ColorCorrectionEffect` under the camera as well as under `Lighting`;
- guards `Lighting.FogColor` and `Lighting.GeographicLatitude`, not just
  `FogEnd`/`ClockTime`.

`lua/probes/fullbright_watch.lua` is the live watcher for this: it forces
fullbright on, logs screen-enable events, and prints the exact surviving
lighting value, effect, atmosphere, or full-screen overlay. Synthetic live
test: forced `exposure=-10`, `brightness=0.3`, black ambient, clock 0, fog 50,
latitude 90, a camera `ColorCorrectionEffect`, and a fake `TeleportScreen`;
all were corrected within one guard tick and the camera effect and screen were
disabled. Toggle-off restored the captured lighting values.

## Voting observations (2026-11-01)

- A Discussion → Voting transition was captured (`Voting` lasted 16.3 s), then
  `=== CYCLE start (day 4) ===` and Night.
- No `talliedVotes` line or event appeared. `gameService` currently exposes
  `skipVote` (RemoteEvent), `canVote` (RemoteFunction), and `canSkipVote`; the
  older `talliedVotes` name was not present in this client build.
- Vote counts therefore appear to be server-only. The menu only surfaces the
  active `UI.mafiavote` target when the game chooses to replicate it.

## Rebuild lessons carried over from the FTF project

- Never hook `FireServer`; it broke the FTF skillcheck. Prefer reading remotes
  and replaying the exact payloads the game itself sends.
- Verify GUI state with `Visible`, not just instance existence.
- Give every feature its own module with an `_G.__mafiaX` API, an instance ID,
  and a clean `Stop()` so hot reload is safe.
- Keep the loader list ordered and the menu last.
- Mock-test Lua offline before running anything live.

## Open questions

- Is the game's night phase instanced or does the whole server share a map?
- Does the client receive the full role list, or only its own role?
- Are there `ProximityPrompt`s for interactions, or custom remotes?
- Does the game expose a spectate/ghost camera after death?
