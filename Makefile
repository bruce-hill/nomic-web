LUA ?= lua
LUAC ?= luac
HOST ?= 127.0.0.1
PORT ?= 8080

# Find rocks installed with `luarocks --lua-version=5.5 install --local`
export LUA_PATH := $(shell luarocks --lua-version=5.5 path --lr-path);;
export LUA_CPATH := $(shell luarocks --lua-version=5.5 path --lr-cpath);;

LUA_SOURCES := server.lua prelude.lua $(wildcard lib/*.lua) $(wildcard tests/*.lua)
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
