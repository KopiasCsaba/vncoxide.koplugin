# Input priority, timing log, per-connection picture settings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** (1) key/page-button bursts are sent without waiting behind screen redraws; (2) a debug-log timing trace showing where redraw time goes on the device; (3) the four picture settings move from the global viewer menu to each connection profile.

**Why (user-confirmed):** on the PocketBook, button presses lag ~1 s, but only while the screen is refreshing — with the shared area unchanged they are instant. KOReader runs decode, paint (`ViewerApp:paintTo` repaints and rescales the whole canvas) and e-ink refresh on one thread, so input waits behind them. The picture settings only apply on (re)connect, so they belong to the connection, not the in-view menu.

**Spec:** this file (follow-up to `docs/superpowers/specs/2026-11-06-bandwidth-buttons-server-script-design.md`).

## Global Constraints

- Pure Lua + LuaJIT FFI; follow existing LDoc/module style.
- Run suites with `../tmp/run-tests.sh [proto|ui|server|py|all]` from the repo root. Never claim a test passed without running it.
- No author names/brands in commits or source.
- The page-buttons setting (`page_buttons`, viewer menu "Page buttons send") stays where it is, unchanged.

## Review Focus

1. A burst of key presses while an update is in flight: every key goes out immediately; exactly one incremental update request is sent once input has been quiet for `INPUT_QUIET`. Test in Task 1.
2. No input at all: update requests behave exactly as before (sent immediately after each FramebufferUpdate). Test in Task 1.
3. A profile saved by the previous branch state (no picture fields) connects as 24-bit / Tight off / JPEG off / compression off. Test in Task 3.
4. Editing picture settings, then pressing Cancel, changes nothing. Test in Task 3.
5. Timing logs cost nothing measurable when debug logging is off (no string formatting on the hot path unless `logger` debug is enabled). Review in Task 2.

---

### Task 1: Hold update requests during input bursts

**Files:** Modify `vnc/protocol.lua` (~line 222-224 auto request), `vnc/session.lua` (`send_key`, `_poll`), `vnc/app.lua` (`scroll_wheel`); Test `tools/proto_smoke.lua` and/or `tools/ui_smoke.lua`.

**Interfaces:**
- `Protocol.new{ ..., hold_updates = function() -> boolean }` (optional). After a FramebufferUpdate, if `hold_updates` returns true, do not send the incremental request; set `self.update_pending = true` instead. `Protocol:release_update()` sends the held incremental request if one is pending (and clears the flag); no-op otherwise. Without `hold_updates`, behaviour is byte-identical to today.
- `Session.INPUT_QUIET = 0.3` (seconds). `Session:note_input()` records `self.last_input = <monotonic now>` (use KOReader's `time.now()`/`time.to_s` from `ui/time` as the rest of the code base does; check what session.lua already uses). `hold_updates` = `last_input` set and `now - last_input < INPUT_QUIET`.
- `Session:send_key` calls `note_input()`; `ViewerApp:scroll_wheel` calls `self.session:note_input()` (pointer events from taps/drags do NOT). `Session:_poll` calls `proto:release_update()` once the quiet period has passed, and then `_flush_tx`.
- `request_full_update` (explicit, e.g. on attach/resize) is never held.

- [ ] Step 1: failing tests: (a) with a mock server, after `note_input()`, the FramebufferUpdate that arrives is decoded but no new FramebufferUpdateRequest is written until `INPUT_QUIET` elapsed and a poll ran — then exactly one; (b) without input the request follows each update immediately (existing behaviour; assert explicitly); (c) `scroll_wheel` and `send_key` set `last_input`; a tap does not. Use an injectable clock if needed (e.g. `Session._now` overridable) rather than sleeping.
- [ ] Step 2: run, see FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(session): hold screen updates while keys are being pressed`.
- [ ] Docs: NOTES.txt short note (why, the 0.3 s, what counts as input); README one line under page buttons.

### Task 2: Timing trace in the debug log

**Files:** Modify `vnc/session.lua`, `vnc/app.lua`, `NOTES.txt` (how to read it), `README.md` (troubleshooting line). Test `tools/ui_smoke.lua`.

**Interfaces:**
- All output via `logger.dbg` with prefix `vnc-timing:` so it only appears with KOReader's debug logging enabled (Developer options → "Enable debug logging"; log in `crash.log`). Guard any non-trivial formatting/clock work behind a cheap check (`logger` level / a module flag `Session.TIMING` set from `G_reader_settings:isTrue("debug_verbose")` or `logger.levels` — choose what KOReader's logger exposes; document it).
- Per FramebufferUpdate: `vnc-timing: update rects=<n> bytes=<b> decode_ms=<cpu ms summed across ticks> wall_ms=<first byte → on_update_done>`.
- Per `ViewerApp:paintTo`: `vnc-timing: paint ms=<ms> canvas=<w>x<h> scale=<s>`.
- Per `_poll` when the gap since the previous `_poll` exceeds 2 × `POLL_INTERVAL`: `vnc-timing: poll gap ms=<ms>` (this captures time the UI thread spent blocked, incl. e-ink refresh).
- Per input note: `vnc-timing: input <key|wheel>` so gaps can be correlated with presses.

- [ ] Step 1: failing ui_smoke check: with timing enabled, a decoded update + paint produce `vnc-timing: update` and `vnc-timing: paint` lines (capture logger.dbg); with timing disabled, none. Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(viewer): debug-log timing trace for decode, paint and blocked polls`.

### Task 3: Picture settings per connection

**Files:** Modify `vnc/settings.lua` (profile fields, remove the four from `DEFAULTS`/`SETTING_CHECKS`), `vnc/dialogs.lua` (connection editor), `vnc/session.lua` (read from the profile), `vnc/menu.lua` (remove Colour depth / Tight encoding / JPEG quality / Compression level entries and the now-unused next-connection helper if nothing else uses it), `README.md`, `NOTES.txt`; Test `tools/ui_smoke.lua`.

**Interfaces:**
- `Settings.PROFILE_FIELDS` gains `color_depth`, `enable_tight`, `jpeg_quality`, `compress_level`. `clean_profile` normalises: `color_depth` ∈ {24,16,8} else 24; `enable_tight` boolean true only; `jpeg_quality`/`compress_level` integer 0..9 else `false`. `save_profile`: an omitted picture field keeps the profile's existing value (same pattern as `autoconnect`).
- The four keys are removed from the global `settings` table (drop them on load; the branch is unreleased, no migration beyond ignoring them).
- Session `_do_connect` builds `PxFmt.for_depth(profile.color_depth)` and `Encodings.order(profile.enable_tight, {jpeg_quality=…, compress_level=…})` from the connecting profile.
- Connection editor (`Dialogs` editor, `MultiInputDialog`): one extra button row above Cancel/Save: a button labelled `Picture: <summary>` (e.g. `Picture: 16-bit, Tight, JPEG 3, compr. 9` / `Picture: 24-bit` when all default). Tapping opens a small menu/ButtonDialog to pick Colour depth (24/16/8), Tight on/off, JPEG quality (Off, 0–9), Compression level (Off, 0–9); JPEG/compression only selectable when Tight is on; each entry has the same help text as before (incl. "Only used at 24-bit colour." for JPEG). Choices are held in the editor and saved only on Save; Cancel discards. After saving the profile that is currently connected, show `InfoMessage` "Reconnect to apply the new settings." (timeout 3).

- [ ] Step 1: failing tests: (a) old profile without the fields loads as 24/false/false/false; invalid values normalise; (b) `save_profile` without picture fields keeps existing ones; (c) editor: change depth to 8 + Tight + JPEG 3, Save → stored on that profile; same changes then Cancel → unchanged; (d) session connecting with that profile hands `Protocol.new` an 8-bpp format and encodings ending in `-29`; (e) the viewer menu no longer has the four entries but still has "Page buttons send". Remove/adapt the old global-setting tests accordingly.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: `all` green. Step 5: commit `feat(connections): picture settings per connection, out of the viewer menu`.
