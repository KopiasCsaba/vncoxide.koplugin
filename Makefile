# VNCoxide plugin: tests and release packaging.
SHELL := /bin/bash
KO    ?= tmp/ko/lib/koreader
KOABS := $(abspath $(KO))
PLUG  := $(CURDIR)
VER   := $(shell sed -n 's/^ *version = "\([^"]*\)".*/\1/p' _meta.lua)

.DEFAULT_GOAL := help
.PHONY: help test release dist publish

help: ## show this help
	@echo "Targets:"
	@echo "  help               show this help (default)"
	@echo "  test               run tests/proto_smoke.lua then tests/ui_smoke.lua (KO=$(KO))"
	@echo "  release V=X.Y.Z    check clean tree + free tag, test, bump _meta.lua, commit, tag vX.Y.Z, build the ZIP"
	@echo "  dist [V=X.Y.Z]     build dist/vncoxide.koplugin-X.Y.Z.zip from tag vX.Y.Z if it exists, else HEAD"
	@echo "  publish            git push origin HEAD and the tag vX.Y.Z (version from _meta.lua)"

test: ## protocol suite, then headless UI suite
	cd "$(KOABS)" && LUA_PATH="$(PLUG)/?.lua;$(KOABS)/common/?.lua;$(KOABS)/common/?/init.lua;;" \
	  LUA_CPATH="$(KOABS)/common/?.so;;" \
	  ./luajit "$(PLUG)/tests/proto_smoke.lua" --tmp "$(PLUG)/tmp/vncv_smoke"
	rm -rf "$(PLUG)/tmp/vncv_ui_home"
	mkdir -p "$(PLUG)/tmp/xdg"; chmod 700 "$(PLUG)/tmp/xdg"
	cd "$(KOABS)" && XDG_RUNTIME_DIR="$(PLUG)/tmp/xdg" SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
	  KO_HOME="$(PLUG)/tmp/vncv_ui_home" LUA_PATH="$(PLUG)/?.lua;;" LUA_CPATH="$(KOABS)/common/?.so;;" \
	  ./luajit "$(PLUG)/tests/ui_smoke.lua"

release: ## see help
	@[[ "$(V)" =~ ^[0-9]+\.[0-9]+\.[0-9]+$$ ]] || { echo "error: V=X.Y.Z required (semver), got '$(V)'" >&2; exit 1; }
	@[ -z "$$(git status --porcelain)" ] || { echo "error: working tree not clean" >&2; exit 1; }
	@! git rev-parse -q --verify "refs/tags/v$(V)" >/dev/null || { echo "error: tag v$(V) already exists" >&2; exit 1; }
	$(MAKE) test
	sed -i -e 's/version = "[^"]*"/version = "$(V)"/' -e 's/Version [0-9.]*/Version $(V)/' _meta.lua
	git commit -am "release: v$(V)"
	git tag -a "v$(V)" -m "v$(V)"
	$(MAKE) dist V=$(V)
	@echo "Release v$(V) built; run \`make publish\` to push"

dist: ## see help
	@V="$(or $(V),$(VER))"; \
	if git rev-parse -q --verify "refs/tags/v$$V" >/dev/null; then ref="v$$V"; else ref=HEAD; fi; \
	mkdir -p dist; \
	git archive --format=zip --prefix=vncoxide.koplugin/ -o "dist/vncoxide.koplugin-$$V.zip" "$$ref" && \
	echo "built dist/vncoxide.koplugin-$$V.zip from $$ref"

publish: ## see help
	git push origin HEAD
	git push origin "v$(VER)"
	@echo "Create the release: https://github.com/KopiasCsaba/vncoxide.koplugin/releases/new?tag=v$(VER)"
	@echo "Attach: dist/vncoxide.koplugin-$(VER).zip"
