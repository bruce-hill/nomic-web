-- Checks JSON encoding
package.path = "lib/?.lua;" .. package.path
local json = require("json")

assert(json.encode({text="a\"\n\255\1"}) == '{"text":"a\\"\\n\239\191\189\\u0001"}', "json encoding")
assert(json.encode({rules={}}) == '{"rules":[]}', "empty tables are arrays")
assert(json.utf8_sanitize("ok\237\160\128é\226") == "ok\239\191\189\239\191\189\239\191\189é\239\191\189", "surrogates and truncated sequences")

print("json: ok")
