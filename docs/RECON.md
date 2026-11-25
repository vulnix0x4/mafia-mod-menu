# Live recon — 2026-11-01

Captured with `lua/probes/recon.lua` and read-only follow-up probes. **No remotes
were invoked and no game objects were changed.**

## Session

| Field | Value |
|---|---|
| `game.PlaceId` | `83705601973004` |
| `game.GameId` (universe) | `7497471789` |
| `game.Name` | `Ugc` |
| Players | 12 |
| Local role | `Harbinger` (Veil) |
| Phase | `DISCUSSION` |

The place in the wiki (`113232329524315`) is the experience entry point; live
rounds run in a sub-place with the same universe ID.

## Where state lives (all client-side)

| Data | Path | Example |
|---|---|---|
| Own role | `PlayerGui.RoleDisplay.Wrapper.Text` | `Your role is: Harbinger` |
| Phase + role | `PlayerGui.Tips...Content.Title` | `DISCUSSION — HARBINGER` |
| Objective | `PlayerGui.Tips...Content.Objective` | `Fill the corruption bar...` |
| Action hint | `PlayerGui.Tips...Content.Action` | `Get people to say what they are.` |
| Corruption | `PlayerGui.NoirApp...Label` | `VEIL CORRUPTION 0%` |
| Players left | `PlayerGui.NoirApp...Label` | `PLAYERS REMAINING: 11` |
| Disguise | `Player:GetAttribute("DisguiseName")` | `Morte` |
| Dead | `Player:GetAttribute("Dead")` | `true` |
| Downed | `Character:GetAttribute("Downed")` | `true` |
| Ragdoll / pose | `Character:GetAttribute("Ragdolled")`, `DeathPosed` | `true` |
| Health | `Character.Humanoid.Health` | `100` |
| Position | `Character.HumanoidRootPart.Position` | direct child of `Workspace` |

`nextNightTransition` exists all round; use `.Enabled` to detect a phase
transition instead of assuming the instance means the transition is active.

## Network surface (names only)

`ReplicatedStorage.RoleNetworks` contains one folder per role:

```text
harbinger  phantom  doctor   detainer  poisoner  mirage    saboteur
snowspirit mafia    detective jester   janitor   witch     vigilante
bodyguard  suppressor judge
```

Examples from the folders:

- `harbinger`: `onGuess`, `firedVigilantes`, `omenReady`, `canUseAbility`
- `mafia`: `onShoot`, `getTeamMembers`, `friendlyFire`, `nightVisionToggled`,
  `teamMembers`, `railgun`, `onStab`, `canKill`
- `detective`: `staminaUpdate`, `playersToIgnore`, `canInvestigate`,
  `investigationInfo`, `onInvestigation`

`ReplicatedStorage.ServiceNetworks` contains 45 service folders, including:

```text
corruptionService  gameService       roleService        interactionService
highlightsService  pointingService   veilChargesService spectatingService
chatService        poisonService     ragdollService     effectsService
```

Notable remotes: `corruptionService.corruption`, `roleService.role`,
`roleService.getRoleNetwork`, `interactionService.interactWith`,
`gameService.nightTransition`, `gameService.tellSpectating`.

These are recorded for future read-only analysis. Payloads have not been
inspected and none of these remotes have been called.

## What players can see

- Only the local role is replicated. Other players expose their disguise name,
  health, position, and dead/downed state — **not their real role**.
- The game's own `playersList` GUI is a role-guessing / assignment board
  ("Assign players the roles you think they are!"), not a live role feed.
- Read-only self-queries (2026-11-01, as Vigilante):
  - `roleService.role:InvokeServer()` → `{ "vigilante" }`
  - `teamService.teamMembers:InvokeServer()` → `{}`
  - `highlightsService.highlights:InvokeServer()` → `{ {} }`
  - `gameService.players:InvokeServer()` → `{ { name = "Alucard", alive = true }, ... }`
    (disguise + alive only, no role field)
- Public role reveals do exist and are now captured by `lua/modules/roles.lua`:
  `gameService.revealRoles`, `gameService.playDeathCutscene`,
  `medalService.clip`, `announcementService.show`, and the round-end cutscene.
  `medalController.publiclyRevealedRoles` = bodyguard, jester, mafia, witch.
- Player chat (`chatService.onSystemMessage`) is not treated as proof.

## Still unknown

1. Remote payloads and validation for night actions and voting.
2. Whether the server accepts client interactions outside the intended range.
3. Anti-cheat behavior around movement, teleports, and remote rate limits.
4. How the Veil corruption integer is encoded in `corruptionService`.
5. Whether dead players receive the full role list through a spectator path.
6. Exact `gameService.revealRoles` payload and timing (hooks are armed; no
   round-end or reveal moment has been captured yet).
7. `medalService.clip` payload shape for publicly revealed roles.
