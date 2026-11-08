LUAJIT ?= luajit
HOST ?= 127.0.0.1
PORT ?= 8080

LUA_SOURCES := server.lua prelude.lua $(wildcard lib/*.lua) $(wildcard tests/*.lua)
TESTS := $(wildcard tests/test_*.lua)

.PHONY: run check test

run:
	$(LUAJIT) server.lua --host $(HOST) --port $(PORT)

# Compile every file to bytecode (and discard it) to catch syntax errors
check:
	@for f in $(LUA_SOURCES); do $(LUAJIT) -b "$$f" /dev/null || exit 1; done
	@echo "syntax: ok"

test: check
	@for t in $(TESTS); do $(LUAJIT) "$$t" || exit 1; done
