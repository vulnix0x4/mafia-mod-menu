# GameFlowLogRemote — client event stream

`ReplicatedStorage.GameFlowLogRemote` is a `RemoteEvent` that streams the game's
own server-side flow log to the client. It fires **only** server → client, so
listening to it is read-only.

## Observed payloads

Phase boundaries:

```text
[GAMEFLOW   165.61s] <<< phase 'Night' END (67.0s)
[GAMEFLOW   165.61s] >>> phase 'Day' START
[GAMEFLOW   180.44s] <<< phase 'Day' END (14.8s)
[GAMEFLOW   180.44s] >>> phase 'Discussion' START
[GAMEFLOW   256.47s] <<< phase 'Voting' END (6.6s)
[GAMEFLOW   256.47s] === CYCLE start (day 2) ===
[GAMEFLOW   256.47s] >>> phase 'Night' START
[GAMEFLOW   261.27s] Night: entering NIGHT_START countdown (lights-out) loop
```

Role-controller noise (filtered by `flowlog.lua`):

```text
role[harbinger].onGameStateChanged START (phase Night)
role[harbinger].onGameStateChanged END
role[mafia].onGamePhaseChangePreperation START (phase Discussion)
```

Body and death events:

```text
[GAME] playBodyFoundCutscene {1={totalDuration=6,bodyFinder=<UserId>,bodyCFrame={...}}}
[GAME] playDeathCutscene {1=VigilanteSelf,2=vigilante}
```

System messages and chat (HTML tags stripped by the feed):

```text
[SYS] <PlayerA> has been shot by <PlayerB>.
[SYS] <PlayerB> paid the ultimate price for murdering an innocent.
[SYS] <PlayerC>: <PlayerD> died
[SYS] <PlayerE>: 1 maf out
```

## Parsed helpers

`flowlog.lua` also exposes:

```lua
_G.__mafiaFlowLog.Phase()   -- latest >>> phase 'X' START
_G.__mafiaFlowLog.Day()     -- latest === CYCLE start (day N) ===
_G.__mafiaFlowLog.Deaths(n) -- last n body/death/chat-death lines
```

The HUD uses `Day()`; STATUS uses `Deaths(3)`.

## What this gives us

- Reliable **phase transitions** (`Night`, `Day`, `Discussion`, `Voting`) and
  cycle/day numbers, independent of the Tips GUI.
- **Body-found** and **death-cutscene** events, including the finder's user ID
  and the local role when the local player dies.
- **System messages** for kills and role-reveal text.
- **Chat**, including player claims and reactions.

## What it does not give us

- Other players' assigned roles. The `role[...]` lines are per-role controller
  lifecycle logs, not role assignments. No player→role mapping is present.
- Vote payloads (we have not observed `talliedVotes` yet).

## Implementation

`lua/modules/flowlog.lua` keeps the last 220 useful lines, drops controller
boilerplate, strips HTML, and exposes:

```lua
_G.__mafiaFlowLog.Lines()
_G.__mafiaFlowLog.Last(n)
_G.__mafiaFlowLog.Clear()
```

The menu's **SYSTEM** tab renders the latest lines and can copy/clear the buffer.
