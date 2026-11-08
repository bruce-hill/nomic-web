-- The initial ruleset. The server runs this as rule code at startup, so it
-- receives the rule capabilities, which player input never gets:
--   persist(code, author)  apply code as a rule change and record it
--   state                  plain data that's saved to disk with the game
--   atomic(fn, ...)        if fn errors, undo its state changes and timers
-- Adopted rule changes receive them too (as `...`), which is how a rule
-- change can replace any of these rules, including the voting procedure.
--
-- Primitives that always exist (rules can shadow them, but not remove them):
--   me()                     the username running the current code
--   users()                  list of connected usernames
--   send(user, text, kind)   send text to one user; kind picks a display style
--   after(seconds, fn)       run fn later, as the current user
local persist, state, atomic = ...

function print(...)
    local parts = {}
    for i = 1, select("#", ...) do
        parts[i] = tostring((select(i, ...)))
    end
    send(me(), table.concat(parts, "\t"))
end

function announce(text)
    for _, user in ipairs(users()) do
        send(user, tostring(text), "announce")
    end
end

function say(text)
    for _, user in ipairs(users()) do
        send(user, me() .. ": " .. tostring(text), "chat")
    end
end

function tell(user, text)
    if not send(user, me() .. " whispers: " .. tostring(text), "whisper") then
        error(tostring(user) .. " is not connected", 2)
    end
    send(me(), "(to " .. tostring(user) .. ") " .. tostring(text), "whisper")
end

function who()
    return table.concat(users(), ", ")
end

-- Called by the server when players connect and disconnect. Everyone who
-- has ever joined is a player.
state.players = state.players or {}

function on_join(user)
    if state.players[user] then
        announce(user .. " has joined")
    else
        state.players[user] = true
        announce(user .. " has joined the game as a new player")
    end
end

function on_leave(user)
    announce(user .. " has left")
end

-- Used by the server to display the values returned by player code
function repr(value, depth, seen)
    depth, seen = depth or 0, seen or {}
    if type(value) == "string" then
        return string.format("%q", value)
    elseif type(value) ~= "table" then
        return tostring(value)
    elseif seen[value] then
        return "<cycle>"
    elseif depth >= 3 then
        return "{...}"
    end
    seen[value] = true
    local parts, n = {}, #value
    for i = 1, n do
        parts[#parts + 1] = repr(value[i], depth + 1, seen)
    end
    for k, v in pairs(value) do
        if not (type(k) == "number" and k >= 1 and k <= n and k % 1 == 0) then
            local key = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k
                or "[" .. repr(k, depth + 1, seen) .. "]"
            parts[#parts + 1] = key .. " = " .. repr(v, depth + 1, seen)
        end
        if #parts > 50 then
            parts[#parts + 1] = "..."
            break
        end
    end
    seen[value] = nil
    return "{" .. table.concat(parts, ", ") .. "}"
end

-- Proposals: any player can propose code as a rule change. It's adopted
-- (run with persist) once more than half of all players vote for it, and
-- rejected once that can no longer happen.
state.proposals = state.proposals or {}
state.next_proposal = state.next_proposal or 1

local function adopt(id)
    local p = state.proposals[id]
    if not p or p.status ~= "passed" then return end
    local ok, err = pcall(atomic, persist, p.code, p.author)
    if ok then
        p.status = "adopted"
    else
        p.status, p.error = "failed", tostring(err)
        announce("Proposal #" .. id .. " passed, but its code failed: " .. tostring(err))
    end
end

-- Proposals that passed right before a restart still need adopting
for id, p in pairs(state.proposals) do
    if p.status == "passed" then after(0, function() adopt(id) end) end
end

local function tally(id)
    local p = state.proposals[id]
    local players, yes, no = 0, 0, 0
    for name in pairs(state.players) do
        players = players + 1
        if p.votes[name] == true then yes = yes + 1
        elseif p.votes[name] == false then no = no + 1 end
    end
    if yes * 2 > players then
        p.status = "passed"
        announce(string.format("Proposal #%d passed, %d to %d", id, yes, no))
        -- Adopt in a run of its own, with a full instruction budget
        after(0, function() adopt(id) end)
    elseif no * 2 >= players then
        p.status = "rejected"
        announce(string.format("Proposal #%d was rejected, %d to %d", id, yes, no))
    end
end

function propose(code, description)
    if type(code) ~= "string" then error("propose(code, description): code must be a string", 2) end
    if description ~= nil and type(description) ~= "string" then
        error("propose(code, description): description must be a string", 2)
    end
    if not state.players[me()] then error("only players can propose rule changes", 2) end
    local id = state.next_proposal
    state.next_proposal = id + 1
    state.proposals[id] = {author = me(), code = code, description = description or "", votes = {}, status = "open"}
    local text = string.format("%s proposed #%d%s:\n%s\n(vote(%d, true) or vote(%d, false))",
        me(), id, description and (" (" .. description .. ")") or "", code, id, id)
    for _, user in ipairs(users()) do send(user, text, "proposal") end
    return id
end

function vote(id, yes)
    local p = state.proposals[id]
    if not p then error("there's no proposal #" .. tostring(id), 2) end
    if p.status ~= "open" then error("proposal #" .. id .. " is already " .. p.status, 2) end
    if type(yes) ~= "boolean" then error("vote(id, yes): yes must be true or false", 2) end
    if not state.players[me()] then error("only players can vote", 2) end
    p.votes[me()] = yes
    announce(me() .. " voted " .. (yes and "for" or "against") .. " proposal #" .. id)
    tally(id)
end

function proposals()
    local lines = {}
    for id = 1, state.next_proposal - 1 do
        local p = state.proposals[id]
        if p and p.status == "open" then
            local votes = {}
            for name, v in pairs(p.votes) do votes[#votes + 1] = name .. (v and " for" or " against") end
            table.sort(votes)
            lines[#lines + 1] = string.format("#%d by %s%s (votes: %s)\n%s", id, p.author,
                p.description ~= "" and (": " .. p.description) or "",
                #votes > 0 and table.concat(votes, ", ") or "none", p.code)
        end
    end
    print(#lines > 0 and table.concat(lines, "\n\n") or "There are no open proposals.")
end

function help()
    print([=[
This is Nomic: the rules are Lua code, and changing them is the game.
Everything you type runs on the server and can use the rules, but can't
change them directly. To change a rule, propose code; it's adopted once a
majority of all players vote for it:

  propose([[ function greet(who) say("hi " .. who) end ]], "add greet")
  vote(1, true)

Adopted code runs as a rule: it receives `persist, state, atomic` as its
arguments (local persist, state, atomic = ...), so it can even replace
propose() and vote() themselves.

  print(...)          show something to yourself
  say(text)           chat to everyone
  announce(text)      broadcast a notice to everyone
  tell(user, text)    whisper to one player
  who()               list connected players
  me()                your username
  users()             table of connected usernames
  send(user, text, kind)  low-level message; kind is a style name
  after(seconds, fn)  run fn later
  propose(code, description)  propose a rule change
  vote(id, yes)       vote on proposal #id (true or false)
  proposals()         list open proposals
  on_join(user), on_leave(user)  hooks the server calls; redefine them!
  repr(value)         formats results shown after `=>`

Ctrl+Enter runs your code. Ctrl+Up/Down browses your history.]=])
end
