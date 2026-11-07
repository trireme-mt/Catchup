# CatchUp - open questions

## To test in game: can we see quests of party members WITHOUT CatchUp?

Right now every party member needs CatchUp installed (each copy sends its own
quest log to the group). A possible fallback for members without it:

The modern client has `C_QuestLog.IsUnitOnQuest(unit, questID)` (Blizzard's UI
uses it to count party members on a quest). Forever runs on the modern client,
so it probably exists there, but this is unconfirmed.

**Test:** group with someone who does NOT have CatchUp and is on a quest whose
ID you know (look it up on Wowhead), then type:

    /dump C_QuestLog.IsUnitOnQuest("party1", 12345)

(replace 12345 with that quest's ID)

Also worth checking:
- Does it still return `true` when they're far away / in another zone?
- Does it return `false` for a quest they're NOT on (sanity check)?

**If it prints `true`:** build the fallback. Use QuestieDB to pick candidate
quests (near their level, allowed for their race/class, not completed by you),
ask the game about each one over a few seconds, and feed the hits into the
existing chain logic. Limitations: needs QuestieDB; can't see their quest
titles or progress; only finds quests within the level range we check.

**If it prints `false`, `nil`, or an error:** keep "everyone installs CatchUp".
