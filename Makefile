LUA ?= lua
LUAC ?= luac
HOST ?= 127.0.0.1
PORT ?= 8080

# Needs the rocks lua-cjson and http. Install http's dependencies yourself and
# then http with --deps-mode=none: it lists bit32, which doesn't exist for 5.5
# and which it doesn't use there.
# Find rocks installed with `luarocks --lua-version=5.5 install --local`
export LUA_PATH := $(shell luarocks --lua-version=5.5 path --lr-path);;
export LUA_CPATH := $(shell luarocks --lua-version=5.5 path --lr-cpath);;

LUA_SOURCES := server.lua $(wildcard lib/*.lua) $(wildcard tests/*.lua)
TESTS := $(wildcard tests/test_*.lua)

.PHONY: run check test

run:
	$(LUA) server.lua --host $(HOST) --port $(PORT)

# Compile every file to bytecode (and discard it) to catch syntax errors
check:
	@for f in $(LUA_SOURCES); do $(LUAC) -p "$$f" || exit 1; done
	@echo "syntax: ok"

test: check
	@for t in $(TESTS); do $(LUA) "$$t" || exit 1; done
