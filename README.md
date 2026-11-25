# MAFIA // Client Toolkit

Client-side tooling for **MAFIA** by Topline Studios (Roblox universe
`7497471789`; live sub-place `83705601973004`). Built for private servers and
authorized client-side testing.

> **Status: v0.2.0.** The menu reads replicated client state, draws local ESP,
> and offers optional local movement/visual changes. It never invokes a
> targeted remote, hooks `FireServer`, teleports, or changes other players.
> The optional team scan is the same no-argument `teamMembers` / `highlights`
> self-query the game client already makes, used only to color teammates.
> Movement/visual toggles are **off by default**. Offline mock suite passes;
> live menu load verified.

---

## The game

MAFIA is a 16-role social-deduction game. Rounds alternate between **Night**
(first-person kills and role actions) and **Day** (discussion, accusations,
vote). Four factions:

| Faction | Goal | Roles |
|---|---|---|
| **Town** | Eliminate the Mafia | Civilian, Detective, Doctor, Janitor, Vigilante, Detainer, Suppressor, Judge |
| **Mafia** | Reach numerical parity | Mafia, Witch |
| **Veil** | Fill the corruption bar to 100% | Harbinger, Mirage, Poisoner, Saboteur |
| **Neutral** | Unique win conditions | Bodyguard, Jester, Snow Spirit, Phantom |

Full research notes: `docs/LEARNINGS.md` · live recon: `docs/RECON.md` ·
event stream: `docs/FLOWLOG.md`.

---

## Quick start

Requirements: Windows, Node.js, and a Roblox executor with `HttpGet` +
`loadstring` (developed against **Potassium**).

```bash
# from this folder
node serve.js
```

The server listens on `127.0.0.1:8766`. Inject with:

```lua
loadstring(game:HttpGet("http://127.0.0.1:8766/lua/loaders/mafia_loader.lua"))()
```

Override the port: `$env:PORT=9000; node serve.js`.

---

## What the menu does

| Tab | Features |
|---|---|
| **ESP** | Local name tags, distance, health, through-wall highlight, dead toggle, max distance (100–1000m); Mafia/Witch teammates are highlighted red instead of green |
| **MOVEMENT** | Noclip, the game's own fly/ghost controller, teleport to player/cursor, spinbot, self-ragdoll, emote spam, character scale, speed slider — all off by default |
| **VISUALS** | EMP-resistant fullbright, camera FOV, reset FOV, repair black screen |
| **SYSTEM** | Live match log (phase/body/death/chat events), dump state/player table/role-network names, copy summary, recenter window, unload |

The old STATUS / PLAYERS / CLAIMS / ROLES tabs are gone from the menu. The
underlying `state`, `claims`, and `roles` modules still load and expose their
`_G` APIs for probes and scripts; they are just not part of the focused panel.

Extras:

- **Sidebar shell** — four focused tabs, a live phase/role/alive card, a
  pulsing connection dot, animated nav state and a per-page slide-in.
- **Status HUD** — optional bottom-left strip: `ROLE · FACTION`, phase, day,
  players left, corruption, an active vote target, and Harbinger power state
  (`locked` / `ready` / `missed`). Toggle it from **SYSTEM → Interface**.
- **Window** — opens top-right below the Roblox topbar; drag the header,
  `_` minimize, `H` recenter, `x` close.
- **Panic** — `End` hides the menu, `Home` recenters it.

### Keybinds

| Key | Action |
|---|---|
| `RightShift` | Toggle menu |
| `F4` | Toggle ESP |
| `Q` | Toggle speed boost |
| `V` | Toggle noclip |
| `X` | Toggle fly / ghost |
| `Y` | Toggle fullbright |
| `K` | Witness-aware Kill (EMP → TP → Knife → EMP → TP back) |
| `Home` | Panic locker (instant escape to nearest empty locker) |
| `PageUp` | Recenter window |
| `End` | Hide menu |

Hotkeys are ignored while the chat text box is focused — click the game or press
`Escape` first. `T` is intentionally left free for role abilities (Vigilante
shoot, Harbinger guess). The game also binds `Q` to the perk action and `F` to
the flashlight, so those two still trigger their normal game actions.

---

## Role data: what is and isn't possible

The client only receives **your own role** plus other players' disguise names,
health, positions, and dead/downed state. There is **no global role table** on
the client — that is why ESP can show `Morte · 42m · 100 hp` but not "Doctor".

What the server does publish:

- `roleService.role:InvokeServer()` → `{ "vigilante" }` (your own role only).
- `teamService.teamMembers:InvokeServer()` → `{}` for solo roles; teammates for
  team roles. `highlightsService.highlights` returns teammate/target tags.
- `gameService.revealRoles`, `gameService.playDeathCutscene`,
  `medalService.clip`, `announcementService.show`, and the round-end cutscene
  are real reveal channels.
- `medalController.publiclyRevealedRoles` lists **bodyguard, jester, mafia,
  witch** — those roles can be revealed publicly on death/medal moments.
- Player chat is *not* proof. `chatService.onSystemMessage` relays ordinary
  chat; "X is the mafia" is a claim, not a reveal.

The **roles module** listens to those reveal channels and records confirmed
roles automatically. Team tags come from game highlights, or from a manual
no-argument team self-query. Everything the server never sends stays a claim or
inference. The focused menu does not render a dedicated roles or players tab;
use `_G.__mafiaRoles` and `_G.__mafiaState.Players()` from a probe or script if
you need that data.

ESP colors Mafia / Witch teammates **red** instead of green. The `Auto team
scan` option performs one no-argument `teamService.teamMembers` self-query when
you get a team role; `Refresh teammates` reruns it manually. Confirmed
Mafia/Witch reveals are also treated as teammates, so a dead or publicly
revealed teammate stays red. The query has no player argument and is the same
call the game client makes.

- A true "see everyone's hidden role" view would require a server-side leak or
  an invalid remote call. Both are out of scope and can get an account banned.
- Changing or selecting a role is server-authoritative. Forging those remotes
  is out of scope.
- The **claims module** remains available for guesses and deductions
  (`_G.__mafiaClaims`), even though it no longer has a menu tab.

---

## Layout

```text
mafia/
├─ lua/
│  ├─ loaders/mafia_loader.lua   ordered module list
│  ├─ modules/
│  │  ├─ core.lua                place guard + shared logging
│  │  ├─ state.lua               role/phase/player reader
│  │  ├─ flowlog.lua             client event feed (phases/deaths/chat)
│  │  ├─ claims.lua              local role-claim notes
│  │  ├─ roles.lua               passive role reveals + team tags
│  │  ├─ movement.lua            noclip / speed / fly / teleport / fun
│  │  ├─ visuals.lua             fullbright / FOV (off by default)
│  │  ├─ esp.lua                 local BillboardGui tags + Highlight
│  │  └─ hud.lua                 compact status strip
│  ├─ menu.lua                   GUI (loaded last)
│  └─ probes/
│     ├─ recon.lua               one-shot client/remote dump
│     ├─ emp_snapshot.lua        lighting/overlay dump for EMP debugging
│     └─ fullbright_watch.lua    live EMP/night guard watcher
├─ docs/
│  ├─ LEARNINGS.md               mechanics + research notes
│  ├─ FLOWLOG.md                 GameFlowLogRemote event stream
│  └─ RECON.md                   live 2026-11-01 client dump
├─ serve.js                      zero-dependency static server (port 8766)
├─ package.json
└─ README.md
```

Module APIs (all `_G`):

| API | Purpose |
|---|---|
| `__mafiaCore` | version, place guard, `Log` |
| `__mafiaState` | `Snapshot()`, `Players()`, `AlivePlayers()`, `FactionForRole()` |
| `__mafiaFlowLog` | `Lines()`, `Last(n)`, `Deaths(n)`, `Phase()`, `Day()`, `Clear()` |
| `__mafiaClaims` | `Get`/`Set`/`Cycle`/`Clear` per player - local notes only |
| `__mafiaRoles` | `Get`/`List`/`Count` (confirmed reveals), `Team`, `ScanHighlights`, `RefreshTeam`, `Raw`, `Reset` |
| `__mafiaMovement` | noclip, speed, fly/ghost, teleport, spin, ragdoll, emote spam, scale; `Stop()` restores |
| `__mafiaVisuals` | fullbright, FOV; `Stop()` restores |
| `__mafiaESP` | `Set`, `Toggle`, `SetOption`, `Options`, `Count`, `RefreshTeam`, `IsTeammate` |
| `__mafiaHUD` | `Set`, `Toggle`, `Enabled` |
| `__mafiaMenu` | `Open`, `Close`, `Set`, `Toggle`, `SetTab("esp" \| "move" \| "visuals" \| "system")`, `Center` |

To add a feature: create `lua/modules/<name>.lua`, publish an `_G.__mafia<Name>`
API with a clean `Stop()`, and append it to `MODULES` before `menu.lua`.

---

## Movement / visual notes

- Noclip sets `CanCollide = false` on your character parts and restores the
  original values when disabled or unloaded.
- Speed sets `Humanoid.WalkSpeed = base × multiplier` every 0.2 s. If the game
  resets speed, the loop reapplies it; if the server validates movement, it may
  snap back.
- Fly anchors the root and moves it by CFrame from WASD/camera input: Space/E
  up, C/Ctrl/Q down, Shift for 3× speed. It mirrors the game's ghost controller
  without its internal `require`, which fails from an executor context. `X`
  toggles it.
- Teleport sets the root CFrame to the nearest player or the cursor raycast
  point. The server may rubber-band long jumps.
- Spinbot rotates the root every render frame with `Humanoid.AutoRotate = false`.
  Ragdoll uses `Humanoid:ChangeState(Ragdoll)` and disables getting up. Emote
  spam cycles the game's `player1` animations. Scale multiplies `BodyHeight`,
  `BodyWidth`, `BodyDepth` and `HeadScale` from the captured defaults.
- Fullbright stores the current `Lighting` values and restores them on off.
  Core lighting (including `ExposureCompensation`) is guarded three ways: a
  `GetPropertyChangedSignal` snap-back that undoes the game's write in the same
  frame it happens, plus reapplies on `RenderStepped`, `Heartbeat`, and
  `BindToRenderStep` at `RenderPriority.Last` (needed because `RenderStepped`
  fires *after* all bound render callbacks). Effects are muted every frame —
  including dark `ColorCorrectionEffect`s — both under `Lighting` and under the
  camera. The known EMP/fade/teleport screens (`Emp`, `EmpAfterimage`, `EmpInk`,
  `Vignette`, `Fade`, `nextNightTransition`, `TeleportScreen`) are disabled per
  frame. `FogColor` and `GeographicLatitude` are guarded as well as
  `FogEnd`/`ClockTime`. A generic sweep hides any full-screen opaque overlay
  the game creates.
- Toggle-off is **safe**: negative exposure is clamped to `0`, blur/DoF are
  never restored to `true`, and EMP/fade screens are never re-enabled. If a
  previous build left the screen black, use **SYSTEM → Repair black screen**
  (or `_G.__mafiaVisuals.Repair()`).
- FOV changes your local camera only.
- **None of these are enabled on load.** Test on an alt/private server first.

---

### EMP still dark?

Run this **while the screen is dark** and send the output:

```lua
loadstring(game:HttpGet("http://127.0.0.1:8766/lua/probes/emp_snapshot.lua"))()
```

It lists Lighting values, post-effects, and every large visible GuiObject with
non-trivial transparency, so we can identify the exact overlay.

For a live watcher that forces fullbright on and logs the exact surviving layer
during night/EMP, use:

```lua
loadstring(game:HttpGet("http://127.0.0.1:8766/lua/probes/fullbright_watch.lua"))()
```

## Roadmap

- [x] Loader, core guard, state reader
- [x] Role / phase / corruption HUD
- [x] Player ESP + live player table
- [x] Noclip, speed, fly, teleport, spin, ragdoll, emote spam, scale, fullbright, FOV
- [x] Read-only diagnostic menu
- [x] Live load test of the full suite
- [x] Manual role-claim board (module API; no menu tab)
- [x] Revealed-role tracker (module API; no menu tab)
- [x] Focused v0.2 menu shell (ESP / MOVEMENT / VISUALS / SYSTEM)
- [ ] Interaction prompt inspector

## Scope

Client-side only. No server execution, no targeted remote calls, no
`FireServer` hooks, no role forcing. The only remote calls are optional
no-argument `teamMembers` / `highlights` self-queries used to color teammates.
Use on servers you control or have explicit permission to test. See
`docs/LEARNINGS.md` for the game's own rules on exploiting.
