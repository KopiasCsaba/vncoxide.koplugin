# Gesture modes: Touch, Mouse, Hybrid — design

## Intent

Browse a desktop web browser over VNC the way one browses on a phone, without the gesture model
becoming confusing. The rule that keeps it simple: **the pointer mode decides what one finger does;
two fingers always handle the view** (pan, zoom, fit).

## Goals

1. A third pointer mode, **Hybrid**: one-finger drag scrolls the remote, tap clicks at the finger.
2. **One long-press rule in every mode**: long press and lift without moving = right click (sent at
   the lift); long press then drag = left-button drag.
3. **Instant taps in Mouse mode**: Mouse mode's tap-then-drag / tap-then-hold (which delay every
   tap by the double-tap interval) are removed; long press then drag replaces them. Two quick taps
   are two clicks (a double click).
4. **Mouse mode follows the pointer when zoomed in, exactly like RustDesk's mobile client**
   (`CursorModel.updatePan`, rustdesk flutter/lib/models/model.dart; notes in
   `tmp/rustdesk-notes.md`).
5. **Scroll lock is removed**: a two-finger drag always moves the picture.

## Non-goals / anti-goals

- No change to two-finger gestures other than dropping scroll lock: pinch zooms (anchored at the
  fingers), two-finger tap fits, two-finger long press is click-and-type.
- No change to the plugin's own VNC server, the key panel, page buttons, or worker mode.
- Anti-goal: any tap getting slower than today in any mode.

## Behaviour

| Gesture | Touch | Mouse | Hybrid |
|---|---|---|---|
| Tap | left click at the finger (instant) | left click at the pointer (instant) | left click at the finger (instant) |
| Two quick taps | double click | double click | double click |
| Drag | left-button drag at the finger | moves the pointer; the view follows (below) | scrolls (wheel notches), content follows the finger |
| Long press, lift without moving | right click at the finger, at the lift | right click at the pointer, at the lift | right click at the finger, at the lift |
| Long press, then drag | left-button drag from the finger | left-button drag from the pointer (relative, view follows) | left-button drag from the finger |
| Two-finger drag / pinch / tap / long press | pan / zoom / fit / click-and-type | same | same |

### Mouse-mode following (RustDesk's algorithm)

Per axis, per move event; `d` = finger delta (screen px) × pointer speed ÷ scale, in remote px:

- Moving towards +: the view pans only if the pointer would pass the view's centre and the view is
  not yet at the remote screen's far edge; then pointer and view move by the same amount (limited
  by the room left). Otherwise only the pointer moves, clamped to the visible area and the remote
  screen.
- Moving towards −: mirrored.
- Effect: the pointer sticks to the view's centre while the view can pan; at the remote edge the
  view stops and the pointer travels on to the side; coming back, the pointer first returns to the
  centre alone, then the view follows again. No jumps.
- A drag that starts with the pointer outside the visible area first moves the pointer to the
  view's centre.
- A two-finger pan or pinch moves the content only; the pointer keeps its remote position.
- While following, the screen uses the fast refresh; the drag's end settles with a normal one (as
  panning does today).

### Hybrid scrolling

Same mechanism as scroll lock's drag-to-wheel today (content follows the finger, sideways scrolls
horizontally, notches go to the finger's position), with a finer step than scroll lock's tenth of
the screen (browsers move ~3 lines per notch); the step is a named constant to tune on the device.

### Toolbar, settings, docs

- The Mode button cycles Touch → Mouse → Hybrid with its toast; a glyph per mode. `pointer_mode`
  accepts `"hybrid"` (per profile, as today).
- Scroll lock disappears from the toolbar, the pinned defaults, the "Toolbar buttons…" menu, the
  help page and the README; stored settings that still name it load without it.
- Help page and README gesture tables get the Hybrid column and the unified long press.

## Approaches considered

1. **Third pointer mode, long press unified (chosen).** One rule per finger count; Hybrid adds no
   toggle; taps stay instant everywhere.
2. Scroll lock with three states (off / two-finger / one-finger scroll): rejected — 2 × 3
   combinations, and one-finger scroll conflicts with Mouse mode's pointer drag.
3. Double tap then drag for the left-button drag (the user's first idea): rejected — either every
   tap waits for the double-tap interval, or the first tap clicks (on a link the browser follows
   it before the drag starts).

## Decisions made by the user

Third mode named Hybrid; scroll lock removed; long press unified across modes; Mouse mode's
tap-then-drag dropped for instant taps; Mouse-mode following as in RustDesk.

## Left to the builder

The hybrid scroll step value; the Hybrid glyph; how the existing false-hold handling (InkView's
burst, `HOLD_CONFIRM`) is kept intact under the new long-press rule — it must stay.
