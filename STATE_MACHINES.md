# State machines

Where the app keeps state that changes over time, what it may be in, and how it moves
between states. Keep this up to date when you change any of these: each machine names
the code it describes.

The server is one process running one cqueues loop. Coroutines switch only where code
yields (socket reads and writes, `condition:wait`). **Game code never yields**: `Game:submit`,
`Game:join` and everything they call (sandboxes, the history file, queueing messages) run
start to finish without another coroutine running. So the only concurrency is between
the coroutines of the connections (S1, S2), not inside the game (G1 to G4).

## Invariants

These are what the machines below exist to keep true.

| # | Invariant | Kept by |
|---|---|---|
| I1 | The game's sandbox is in the state you get by replaying `game.history` in a new sandbox. | G1: every request that the sandbox handles is added to the history, whatever happens. Replays use the tries that were recorded (G3), and limits that don't depend on time (G2). |
| I2 | The history file holds `game.history`, or will after the next save. | H1 |
| I3 | Every player in `by_name` has a connection that is reading, and is listed once in `user_order`. | S1 |
| I4 | A client shows each announcement once. | C2 |
| I5 | `game.joined[p]` is true exactly when the history has a `join` request from `p`. | `Game:note` |
| I6 | A player's sandbox (a fork) never changes the game: the only way out is the requests it sends. | G2 effects |

## G1: Handling a request (`Game:handle`, lib/nomic.lua)

One pass of this machine for each request: from `Game:join`, and for each request that a
submission sends (up to `MAX_REQUESTS`).

| From | Event | To |
|---|---|---|
| start | request doesn't serialize, or is over `MAX_REQUEST` | **refused**: reply with an error. Nothing changes. |
| start | request is plain data | **running** in the game's sandbox, with effects that print into a buffer and call `Game:trial` for tries |
| running | the rules finish, or fail (error or limit) | **handled**: the sandbox may have changed, either way |
| handled | `Game:note` | **noted**: in `history`, `recent` and `joined` |
| noted | `record` (H1) | **recorded** |
| recorded | | announce what was said, send the rules if there are more of them, reply with the error if the rules failed |

Between **running** and **recorded** nothing may raise an error, or I1 breaks: the sandbox
has changed, but the history doesn't say why.

## G2: A sandbox (`Sandbox`, lib/nomic.lua)

Fields that change: `effects`, `tries`, `rules`, `nomsu.limits`, and `RUNTIME_ENV.event`
(set only while it handles an event).

| Kind | Made by | Limits | Effects |
|---|---|---|---|
| game | `Game.new`, once | `REPLAYED_LIMITS` (instructions and memory, no time limit) | live (G1), or `replaying(entry)` at startup |
| fork | `Game:fork`, for each submission and each try | `REPLAYED_LIMITS` while it replays the history, then `LIVE_LIMITS` (adds a 1 second limit) | the player's, or `SILENT` for a try |

| From | Event | To |
|---|---|---|
| new | `Sandbox.new`: kernel, `seal()`, starting rules | **ready** with 5 rules |
| ready | `run(code, effects)` | **running** with those effects and `tries = 0` |
| running | `enact` succeeds | running, with one more rule |
| running | `try enacting`, while `tries <= MAX_TRIES` | running: calls `effects.try` |
| running | `try enacting`, after `MAX_TRIES` | the run fails |
| running | finishes or fails | **ready**. `effects` still points to the last run's effects, which nothing calls between runs. |

A fork's `SILENT.try` raises an error, so trying something in a try can't recurse.

## G3: Tries (`Game:trial`, recorded in `entry.recorded`)

| Where | What `try enacting` gives |
|---|---|
| the game, live | `Game:trial(code)`, run in a fork outside the limits of the running code; its result (or `false`) is appended to `entry.recorded` |
| the game, replaying | the next result from `entry.recorded` (`false` gives nil) |
| a player's fork | `Game:trial(code)`, which isn't recorded, since forks aren't saved |
| a try's fork | an error |

The live and replayed runs see the same results in the same order, as long as the rules
make the same tries. They do if I1 holds before the entry.

## G4: Recent announcements (`game.recent`)

A list of `{seq, text}`, at most `MAX_RECENT`, oldest first. `seq` is the position of the
entry in `game.history`, so it goes up by at least 1 each time, and is the same after a
restart (it's rebuilt by replaying). The same seq comes with the live announcement.

## H1: The history file (`History`, lib/history.lua)

The file is complete entries, each followed by `"\n--\n"`, and maybe an unfinished entry
at the end (a write that was cut short).

| From | Event | To |
|---|---|---|
| (start) | `History.open`, the file ends cleanly | **clean** |
| (start) | `History.open`, it ends with an entry that only lacks its separator | keeps the entry, rewrites the file: **clean** |
| (start) | `History.open`, it ends with an unfinished entry | drops it (the server logs it), rewrites the file: **clean** |
| (start) | an entry before the last separator doesn't load | error: the server doesn't start (don't silently lose history) |
| clean | `append` succeeds | clean |
| clean | `append` fails (opening, writing or closing) | **broken**: the file may lack this entry or end with part of it |
| broken | `append` | `rewrite` all of `game.history` to `FILE.tmp`, then rename it over the file: **clean** if that worked, else still broken |

## S1: A connection (`on_stream` and `play`, server.lua)

| From | Event | To |
|---|---|---|
| request | not a GET | 405 |
| request | `/` or `/index.html` | the page |
| request | `/ws`, but not an upgrade | 400 |
| request | `/ws` upgrade | **accepted** |
| accepted | the name is invalid or someone online has it | sends `rejected`, closes with 1008: **closed** |
| accepted | otherwise (no yield between the check and the next step) | **playing**: in `by_name` and `user_order`; a writer (S2) starts; queues `welcome` (with the history's length as `seq`), `users` to everyone, `rules`, the recent announcements, then `Game:join` (protected like submissions) |
| playing | a text message of at most `max_message` bytes | `Game:submit` (protected): playing |
| playing | a message that's too long, the client closes, or the socket fails (S2 shuts it down) | **leaving**: out of `by_name` and `user_order`, `conn.closed`, wakes the writer, closes the WebSocket (this yields) |
| leaving | | **closed**: sends `users` to everyone |

The name is free again once **leaving** starts, so the same player can reconnect while
the old WebSocket is still closing.

## S2: A connection's writer (`write_messages`, server.lua)

| From | Event | To |
|---|---|---|
| waiting | a message is queued | **sending** (yields; drops the connection after `send_timeout`) |
| sending | sent | waiting, or sending the next one |
| sending | failed or timed out | shuts down the socket if it's open, which ends S1's read: **done** |
| waiting | `conn.closed` and nothing is queued | **done** |

## C1: The browser's connection (public/index.html)

| From | Event | To |
|---|---|---|
| logged out | submit the login form | **connecting**: drops any older socket's `onclose` handler and closes it |
| connecting | `welcome` | **online**: saves the name, hides the login, enables Run |
| connecting | `rejected` | shows why; the server closes the socket |
| connecting | closed | **logged out**: "Couldn't connect" unless a rejection is showing |
| online | closed | **logged out**: "Disconnected. Reconnect?" |

The code input's history (Ctrl+Up/Down) is separate: `historyPos` is between 0 and
`history.length`; at `history.length` the input shows the unsent draft.

## C2: Announcements in the browser

`lastSeq` is the seq of the last announcement shown. An announcement with a seq at or
below it is skipped, since it's already in the log. A `welcome` whose seq (the history's
length) is less than `lastSeq` means the server started a new game, so it resets to 0.

---

## Problems found

Found by reading the code above and confirmed by running it, unless it says otherwise.
Listed by impact.

### Issue 1: Things that happened in the game could be missing from its history (I1, I2) — fixed

**1a. A request that isn't a table broke the game's history.** `Game:note` read
`entry.request.type`, which raises an error for a number or boolean. Player code can send
these (`send 5`). The error came after the game's sandbox handled the request, so the
request changed the game but wasn't in the history or saved. After a restart, or in
every player's fork, the game was different. Repro: enact a `(handle $event)` that counts
events, then `send 5`. The live game counted 1, and replaying it counted 0.
Fix: `Game:note` checks the request's type. Tests: "replaying requests that aren't tables
gives the same state" (tests/test_nomic.lua).

**1b. A failed save left the history file without the entry, or with part of it.**
`save_entry` ignored errors from `f:close()`, which is where buffered writes fail (a
full disk). After any failure it kept appending, so the file either lacked the entry for
good (later entries replayed without it) or had part of it with the next entry glued on.
**1c. A file ending with an unfinished entry stopped the server from starting** after
the next append, since that glued entry doesn't parse. A crash in the middle of a write
leaves this.
Fix: lib/history.lua (H1). Tests: tests/test_history.lua.

### Issue 2: Reconnecting showed the recent announcements again (I4) — fixed

On connecting, the server sends up to 100 recent announcements, and the browser added
them to its log, which still had them from before. Fix: announcements carry a seq (G4,
C2). Tests: "announcements are numbered by history entry" and "recent announcements keep
their numbers" (tests/test_nomic.lua). The browser's part has no automated test; it was
checked by connecting twice with a WebSocket client and reading the seqs.

### Issue 3: An error while joining would have left a ghost player (I3) — hardened

`play` called `Game:join` unprotected, so an error from it would skip the cleanup: the
name would stay taken and listed online until a restart. Nothing could be found that
raises an error there now (1a was the closest), so this is a precaution. Fix: protect it
like submissions.

### Known risks, not fixed

- **The memory limit depends on the garbage collector.** `nomsu_limits` measures memory as
  `collectgarbage("count")` minus the count when the run started. Garbage left over from
  before (a fork, say) is in the starting count, and if it's collected during the run,
  the run can use that much more. So the same handler could pass live and fail on replay,
  breaking I1. Not reached in practice: `memory = 256 * 1024` is in KB (256 MB), far more
  than a run can use under its instruction limit; tried retaining 80,000 entries with
  garbage left around, and live and replay agreed. If the limit is lowered, run a full
  `collectgarbage()` before each run of the game's sandbox, or count memory another way.
- **A silently dead client keeps its name.** There is no read timeout or ping, so if a
  client's network drops without closing (a laptop sleeping), its connection stays
  **playing** until TCP gives up or the writer times out sending to it. Meanwhile the
  player gets "already taken". Fixing it needs pings, and a read timeout that doesn't
  count the pongs that lua-http swallows.
- **A connection's message queue (`conn.out`) has no limit.** A client that reads just
  fast enough to avoid `send_timeout` lets it grow.
- **Closing and writing at the same time.** When S1 starts **leaving**, `ws:close()` can
  write a close frame while S2 is partway through writing a message on the same socket.
  Not confirmed whether cqueues can interleave the two frames. The result would be a
  broken close on a connection that is closing anyway.
- **A new game is only noticed if it has fewer entries.** If the server is started with a
  new history that has already grown past a client's `lastSeq` by the time it reconnects,
  that client skips announcements it hasn't seen.
