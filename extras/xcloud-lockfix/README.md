# xCloud pointer-lock fix

Cloud-gaming players (Xbox Cloud Gaming, GeForce NOW, ...) ask the browser for a **raw** pointer lock:

```js
element.requestPointerLock({ unadjustedMovement: true })
```

On macOS that puts Chromium's pointer lock on a raw-input path where injected mouse movement is
reported as `movementX === 0`. Every synthetic event (a remote-desktop layer, an automation tool) is
therefore delivered but discarded: the cursor never moves, while scrolling still works.

## Install (once)

1. Open `chrome://extensions`
2. Turn on **Developer mode** (top right)
3. **Load unpacked** → select this folder

Reload the game tab. Pointer lock now uses the adjusted path, so relative movement arrives normally.

## Note

If the game feels different, it is because this disables raw/unaccelerated mouse input — which is
what makes remote input possible at all.
