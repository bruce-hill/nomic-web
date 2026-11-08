-- Plays a short game of Nomic, then checks that replaying it gives the same game
package.path = "lib/?.lua;" .. package.path
local Game = require("nomic")
local store = require("store")

local announced, replies, saved, rule_updates = {}, {}, {}, {}
local function new_game(entries)
    return Game.new({
        entries = entries,
        announce = function(text) announced[#announced + 1] = text end,
        record = function(entry) saved[#saved + 1] = store.serialize(entry) end,
        rules_changed = function(rules) rule_updates[#rule_updates + 1] = #rules end,
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
say "first is \($game.players.1)"]], reply)
expect(has(replies, "result: first is mallory"), "sandbox output goes to the player")
expect(not has(announced, "first is mallory"), "sandbox output isn't announced")
game:submit("alice", [[say "first is \($game.players.1)"]], reply)
expect(has(replies, "result: first is alice"), "sandbox changes don't last")

-- Limits and errors
replies = {}
game:submit("alice", "repeat:\n    do nothing", reply)
expect(has(replies, "limit"), "infinite loops are stopped")
replies = {}
game:submit("alice", [[say (1 + {})]], reply)
expect(has(replies, "error: "), "errors are reported")
replies = {}
game:submit("alice", [[say "still \($game.players.2)"]], reply)
expect(has(replies, "result: still bob"), "the game still works after errors")

-- Anyone's proposal is enacted right away
game:submit("bob", [[
propose:
    public:
        (greeting) means "hi"]], reply)
expect(has(announced, "bob enacted:"), "proposals are announced")
replies = {}
game:submit("carol", [[say (greeting)]], reply)
expect(has(replies, "result: hi"), "a proposal is enacted without any vote")
expect(#game:rules() == 6 and rule_updates[1] == 6, "enacted proposals join the rules")
expect(string.find(game:rules()[6], 'means "hi"', 1, true), "the rules show what was enacted")

-- A proposal with an error doesn't change anything
announced = {}
game:submit("bob", 'propose:\n    say (1 + {})', reply)
expect(has(announced, "rejected"), "proposals with errors are rejected")
expect(#game:rules() == 6, "rejected proposals don't join the rules")

-- Requests that nothing handles are reported
announced = {}
game:submit("bob", 'send {.type = "dance", .args = {}}', reply)
expect(has(announced, 'Nothing handles "dance" requests.'), "unknown requests are reported")

-- One (on ...) defines both the action and its handler
announced = {}
game:submit("bob", [[
propose:
    on (wave at $other) from $player:
        say "\$player waves at \$other."]], reply)
game:submit("carol", 'wave at "alice"', reply)
expect(has(announced, "carol waves at alice."), "(on ...) defines a request with arguments")

-- Handlers receive their arguments unpacked, in position even if some are nil
announced = {}
game:submit("bob", [[
propose:
    on (rate $thing with $stars and $note) from $player:
        say "\$player rated \$thing: \$stars, \$note."]], reply)
game:submit("carol", 'rate "soup" with (nil) and "salty"', reply)
expect(has(announced, "carol rated soup: nil, salty."), "nil arguments keep their position")
game:submit("bob", [[
propose:
    set the handler for "shrug" to ({$player, $how} -> (say "\$player shrugs \$how."))]], reply)
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
                say "Proposal \$n passes."
                enact $proposal.code
                $game.turn = (($game.turn mod #$game.players) + 1)
                say "It's \(whose turn it is)'s turn."
    on (submit proposal $code) from $player:
        unless ($player == (whose turn it is)):
            say "\$player can't propose now, since it's \(whose turn it is)'s turn."
            return
        $problem = (try enacting $code)
        if $problem:
            say "\$player's proposal was rejected: \$problem"
            return
        $n = $game."next proposal"
        $game."next proposal" += 1
        $game.proposals.$n = {.code = $code, .votes = {}}
        say "Proposal \$n, by \$player."
    on (vote yes on proposal $n) from $player:
        count "yes" from $player on proposal $n
    on (vote no on proposal $n) from $player:
        count "no" from $player on proposal $n]], reply)
expect(has(announced, "alice enacted:"), "voting is enacted")
replies = {}
game:submit("alice", [[say (whose turn it is)]], reply)
expect(has(replies, "result: alice"), "turns start with the first player")
game:submit("bob", 'propose:\n    do nothing', reply)
expect(has(announced, "bob can't propose now"), "the new rule limits who can propose")
game:submit("alice", [[
propose:
    public:
        (greeting) means "hello"]], reply)
expect(has(announced, "Proposal 1, by alice."), "proposals now wait for a vote")
replies = {}
game:submit("carol", [[say (greeting)]], reply)
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
loaded:submit("alice", [[say "\(greeting) \(whose turn it is)"]], reply)
expect(has(replies, "result: hello bob"), "replaying history restores the game")
expect(#loaded.recent > 0, "recent announcements are restored")
expect(#loaded:rules() == count, "replaying history restores the list of rules")

-- The help and starting rules work
replies = {}
loaded:submit("alice", "help\nsay (current rules)", reply)
expect(has(replies, "tell everyone") and has(replies, "Rule 5") and has(replies, "Rule 6: enacted"),
    "help and the current rules")

if failures > 0 then
    print(failures .. " nomic test(s) failed")
    os.exit(1)
end
print("nomic: ok")
