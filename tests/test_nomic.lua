-- Plays a short game of Nomic, then checks that replaying it gives the same game
package.path = "lib/?.lua;" .. package.path
local Game = require("nomic")
local store = require("store")

local announced, replies, saved, rule_updates = {}, {}, {}, {}
local function new_game(entries)
    return Game.new({
        entries=entries,
        announce=function(text) announced[#announced + 1] = text end,
        record=function(entry) saved[#saved + 1] = store.serialize(entry) end,
        rules_changed=function(rules) rule_updates[#rule_updates + 1] = #rules end,
    })
end
local function reply(text, kind) replies[#replies + 1] = kind .. ": " .. text end

local game = new_game()
local failures = 0
local function expect(cond, what)
    if not cond then
        failures = failures + 1
        print("FAIL " .. what)
        print("  announced: " .. table.concat(announced, "\n  "))
        print("  replies: " .. table.concat(replies, "\n  "))
    end
end
local function has(list, text)
    for _, line in ipairs(list) do
        if string.find(line, text, 1, true) then return true end
    end
    return false
end

for _, name in ipairs({"alice", "bob", "carol"}) do game:join(name, reply) end
expect(has(announced, "alice joined the game."), "players can join")
local joins = #saved
game:join("alice", reply)
expect(#saved == joins, "joining again does nothing")

-- What a player does in their own copy doesn't change the game
game:submit("alice", [[
$game.players.1 = "mallory"
print "first is \($game.players.1)"]], reply)
expect(has(replies, "result: first is mallory"), "sandbox output goes to the player")
expect(not has(announced, "first is mallory"), "sandbox output isn't announced")
game:submit("alice", [[print "first is \($game.players.1)"]], reply)
expect(has(replies, "result: first is alice"), "sandbox changes don't last")

-- Limits and errors
replies = {}
game:submit("alice", "repeat:\n    do nothing", reply)
expect(has(replies, "limit"), "infinite loops are stopped")
replies = {}
game:submit("alice", [[print (1 + {})]], reply)
expect(has(replies, "error: "), "errors are reported")
replies = {}
game:submit("alice", [[print "still \($game.players.2)"]], reply)
expect(has(replies, "result: still bob"), "the game still works after errors")

-- Anyone's proposal is enacted right away
game:submit("bob", [[
propose:
    public:
        (greeting) means "hi"]], reply)
expect(has(announced, "bob enacted:"), "proposals are announced")
replies = {}
game:submit("carol", [[print (greeting)]], reply)
expect(has(replies, "result: hi"), "a proposal is enacted without any vote")
expect(#game:rules() == 6 and rule_updates[1] == 6, "enacted proposals join the rules")
expect(string.find(game:rules()[6], 'means "hi"', 1, true), "the rules show what was enacted")

-- A proposal with an error doesn't change anything
announced = {}
game:submit("bob", 'propose:\n    print (1 + {})', reply)
expect(has(announced, "rejected"), "proposals with errors are rejected")
expect(#game:rules() == 6, "rejected proposals don't join the rules")
expect(not game:submit("bob", 'propose:\n    print (1 + {})', reply), "errors when running aren't compile errors")

-- Code that can't be compiled says why, and the player is told so they can fix it
announced, replies = {}, {}
expect(game:submit("bob", 'propose:\n    stop', reply), "proposals that don't compile are reported")
expect(has(announced, "Couldn't compile this code: break outside loop"), "proposals that don't compile say why")
expect(game:submit("bob", 'stop', reply), "code that doesn't compile is reported")
expect(has(replies, "error: Couldn't compile this code: break outside loop"), "code that doesn't compile says why")
expect(game:submit("bob", 'print (foo }', reply), "code that doesn't parse is reported")
expect(#game:rules() == 6, "proposals that don't compile don't join the rules")

-- Requests that nothing handles are reported
announced = {}
game:submit("bob", 'send {.type = "dance", .args = {}}', reply)
expect(has(announced, 'Nothing handles "dance" requests.'), "unknown requests are reported")

-- One (on ...) defines both the action and its handler
announced = {}
game:submit("bob", [[
propose:
    on (wave at $other) from $player:
        print "\$player waves at \$other."]], reply)
game:submit("carol", 'wave at "alice"', reply)
expect(has(announced, "carol waves at alice."), "(on ...) defines a request with arguments")

-- Handlers receive their arguments unpacked, in position even if some are nil
announced = {}
game:submit("bob", [[
propose:
    on (rate $thing with $stars and $note) from $player:
        print "\$player rated \$thing: \$stars, \$note."]], reply)
game:submit("carol", 'rate "soup" with (nil) and "salty"', reply)
expect(has(announced, "carol rated soup: nil, salty."), "nil arguments keep their position")

-- Players can see which actions exist, and which are the game's rather than Nomsu's
local function action(pattern)
    for _, a in ipairs(game:actions()) do
        if a.pattern == pattern then return a end
    end
end
expect(action("rate $thing with $stars and $note").game, "the rules' actions are listed")
expect(action("rate $thing with $stars and $note").rule == #game:rules(), "actions say which rule defines them")
expect(action("join").rule == 2, "the starting rules' actions say which rule defines them")
expect(action("on $pattern from $player $body").game, "the kernel's actions are listed")
expect(action("$list joined with $glue") and not action("$list joined with $glue").game,
    "Nomsu's actions are listed")
expect(action("$ isn't empty"), "actions are listed the way they're typed")
game:submit("bob", [[
propose:
    set the handler for "shrug" to ({$player, $how} -> (print "\$player shrugs \$how."))]], reply)
game:submit("carol", 'send {.type = "shrug", .args = {"sadly"}}', reply)
expect(has(announced, "carol shrugs sadly."), "handlers can be registered directly")

announced = {}
game:submit("carol", "join", reply)
expect(not has(announced, "joined"), "players can't join twice")

-- Majority voting and turns can be added later, as ordinary proposals
announced = {}
game:submit("alice", [[
propose:
    $game.proposals = {}
    $game."next proposal" = 1
    $game.turn = 1
    public:
        (whose turn it is) means $game.players.($game.turn)
        (count $vote from $player on proposal $n) means:
            $proposal = $game.proposals.$n
            unless $proposal: return
            $proposal.votes.$player = $vote
            $yes = 0
            for ($voter = $choice) in $proposal.votes:
                if ($choice == "yes"):
                    $yes += 1
            if (($yes * 2) > #$game.players):
                $game.proposals.$n = (nil)
                print "Proposal \$n passes."
                enact $proposal.code
                $game.turn = (($game.turn mod #$game.players) + 1)
                print "It's \(whose turn it is)'s turn."
    on (submit proposal $code) from $player:
        unless ($player == (whose turn it is)):
            print "\$player can't propose now, since it's \(whose turn it is)'s turn."
            return
        $problem = (try enacting $code)
        if $problem:
            print "\$player's proposal was rejected: \$problem"
            return
        $n = $game."next proposal"
        $game."next proposal" += 1
        $game.proposals.$n = {.code = $code, .votes = {}}
        print "Proposal \$n, by \$player."
    on (vote yes on proposal $n) from $player:
        count "yes" from $player on proposal $n
    on (vote no on proposal $n) from $player:
        count "no" from $player on proposal $n]], reply)
expect(has(announced, "alice enacted:"), "voting is enacted")
replies = {}
game:submit("alice", [[print (whose turn it is)]], reply)
expect(has(replies, "result: alice"), "turns start with the first player")
game:submit("bob", 'propose:\n    do nothing', reply)
expect(has(announced, "bob can't propose now"), "the new rule limits who can propose")
game:submit("alice", [[
propose:
    public:
        (greeting) means "hello"]], reply)
expect(has(announced, "Proposal 1, by alice."), "proposals now wait for a vote")
replies = {}
game:submit("carol", [[print (greeting)]], reply)
expect(has(replies, "result: hi"), "proposals aren't enacted before the vote")
game:submit("alice", "vote yes on proposal 1", reply)
game:submit("bob", "vote yes on proposal 1", reply)
expect(has(announced, "Proposal 1 passes."), "a majority passes a proposal")
expect(has(announced, "It's bob's turn."), "the turn moves on")

-- Loaded from what was saved, the game has the same rules and state
local entries = {}
for i, text in ipairs(saved) do entries[i] = store.deserialize(text) end
local count = #game:rules()
local loaded = new_game(entries)
replies = {}
loaded:submit("alice", [[print "\(greeting) \(whose turn it is)"]], reply)
expect(has(replies, "result: hello bob"), "replaying history restores the game")
expect(#loaded.recent > 0, "recent announcements are restored")
expect(#loaded:rules() == count, "replaying history restores the list of rules")

-- The help and starting rules work
replies = {}
loaded:submit("alice", "help\nprint (current rules)", reply)
expect(has(replies, "say") and has(replies, "Rule 5") and has(replies, "Rule 6: enacted"),
    "help and the current rules")

-- Printing is only seen by the player, and saying is seen by everyone
local talking = new_game()
talking:join("alice", reply)
announced, replies = {}, {}
talking:submit("alice", 'print "just for me"', reply)
expect(has(replies, "result: just for me"), "print shows the text to the player")
expect(not has(announced, "just for me"), "print isn't announced")
replies = {}
talking:submit("alice", 'say "hi all"', reply)
expect(has(announced, "@alice: hi all"), "say is announced with the player's name")
expect(not has(replies, "hi all"), "say doesn't print locally")

-- What saying means can be changed by a proposal
talking:submit("alice", [[
propose:
    on (say $message) from $player:
        print "\$player shouts \$message!"]], reply)
announced = {}
talking:submit("alice", 'say "hey"', reply)
expect(has(announced, "alice shouts hey!"), "proposals can redefine say")

-- A proposal is tried in a copy of the game, which can print
local trying = new_game()
trying:join("alice", reply)
announced = {}
trying:submit("alice", 'propose:\n    print "hello from a rule"', reply)
expect(not has(announced, "rejected"), "proposals that print aren't rejected")
expect(has(announced, "hello from a rule"), "what an enacted proposal says is announced")

-- The copy has the proposals that were enacted before
trying:submit("alice", 'propose:\n    public:\n        (zork) means 1', reply)
announced = {}
trying:submit("alice", 'propose:\n    $x = (zork)', reply)
expect(not has(announced, "rejected"), "proposals can use what earlier proposals defined")

-- The copy can't start another trial
announced = {}
trying:submit("alice", 'propose:\n    try enacting "do nothing"', reply)
expect(has(announced, "can't try enacting"), "a copy of the game can't try enacting")

-- Requests sent while replaying history aren't handled again
trying:submit("alice", [[
propose:
    on (ping) from $player:
        say "pong"]], reply)
trying:submit("alice", "ping", reply)
announced = {}
trying:submit("alice", "do nothing", reply)
expect(not has(announced, "pong"), "replaying history doesn't send requests")

-- Requests that aren't tables are handled and saved like any others, so replaying the
-- game gives the same state
local odd = new_game()
odd:join("alice", reply)
odd:submit("alice", [[
propose:
    $game.events = 0
    public:
        (handle $event) means:
            $game.events += 1]], reply)
saved = {}
for _, request in ipairs({"5", "(yes)", '"text"'}) do
    local ok, err = pcall(odd.submit, odd, "alice", "send " .. request, reply)
    expect(ok, "sending " .. request .. " doesn't fail (got " .. tostring(err) .. ")")
end
expect(#saved == 3, "requests that aren't tables are saved")
replies = {}
odd:submit("alice", "print $game.events", reply)
local live_events = replies[#replies]
entries = {}
for _, entry in ipairs(odd.history) do entries[#entries + 1] = store.deserialize(store.serialize(entry)) end
replies = {}
new_game(entries):submit("alice", "print $game.events", reply)
expect(live_events == "result: 3" and replies[#replies] == live_events,
    "replaying requests that aren't tables gives the same state (live "
    .. tostring(live_events) .. ", replayed " .. tostring(replies[#replies]) .. ")")

-- Announcements are numbered by their place in the history, the same after replaying
local seqs = {}
local numbered = Game.new({
    announce=function(_, seq) seqs[#seqs + 1] = seq end,
    record=function() end,
    rules_changed=function() end,
})
numbered:join("alice", reply)
numbered:submit("alice", "do nothing", reply)
numbered:join("bob", reply)
numbered:submit("bob", 'say "hi"', reply)
expect(table.concat(seqs, " ") == "1 2 3", "announcements are numbered by history entry (got "
    .. table.concat(seqs, " ") .. ")")
local renumbered = new_game(numbered.history)
local recent = {}
for i, said in ipairs(renumbered.recent) do recent[i] = said.seq .. "=" .. said.text end
expect(table.concat(recent, " ") == "1=alice joined the game. 2=bob joined the game. 3=@bob: hi",
    "recent announcements keep their numbers (got " .. table.concat(recent, " ") .. ")")

if failures > 0 then
    print(failures .. " nomic test(s) failed")
    os.exit(1)
end
print("nomic: ok")
