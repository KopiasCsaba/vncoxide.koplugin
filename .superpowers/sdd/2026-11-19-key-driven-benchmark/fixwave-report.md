# Fix wave report

1. benchresults.lua: a card's tap range is now its dimen clipped to the scroll container's visible area (`BenchResults:visible_area`, `Card:visible_dimen`); the strip below a truncated card and scrolled-out parts do nothing.
   Test `benchcards_hidden_card_not_tappable` (ui_smoke, 14 rows on 1264x1680): tap on the blank strip picks nothing, tap on a visible card picks it.
   Mutation check: with `visible_dimen` clipping disabled the check fails ("a tap on the blank strip picks nothing: 1"); restored afterwards.
2. benchmark.lua: `Benchmark.RESET_TIMEOUT = 15` used for the reset phase only; header doc updated. proto_smoke: `benchmark_key_reset_may_take_longer_than_a_step` (reset busy 8 s on the fake clock: run succeeds) and `benchmark_key_reset_that_never_settles_fails` (fails with "did not settle within 15 s after the reset"); the busy screen is simulated by holding `_settled` back (restored after each run), no mock change.

Tests: `tmp/run-tests.sh ui` -> "all checks passed"; `tmp/run-tests.sh proto` -> "all checks passed".
