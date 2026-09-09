# Procedural IK Walker

A six-legged walker for Roblox. Feet are placed by raycasting the world, knees are
solved analytically with the law of cosines, and the chassis floats on the plane
described by whichever feet are currently planted.

**Submission file:** [`ProceduralIkWalker.lua`](ProceduralIkWalker.lua)

## What it does

- **Two-bone IK** ➔ closed-form solve per leg using the law of cosines. No iteration,
  so cost is constant regardless of limb configuration.
- **Raycast foot placement** ➔ each leg probes for ground beneath its rest target and
  plants where the surface actually is, so the rig adapts to stairs, slopes and rubble.
- **Tripod gait** ➔ legs are split into two alternating groups, with a hard budget that
  never allows more than half the legs off the ground at once. A leg stretched near its
  reach limit may jump the queue.
- **Body plane solve** ➔ ride height comes from the average planted foot; pitch and roll
  come from the spread between front/rear and left/right feet, so the body banks into slopes.
- **Framerate independent smoothing** ➔ exponential easing on ride height and rotation,
  so the rig settles identically at 30fps and 240fps.

## Running it

Place the script in `StarterPlayer/StarterPlayerScripts` as a `LocalScript`. It builds
its own rig at runtime ➔ no models or assets required ➔ and follows the local player's
character, holding a standoff distance.

Everything is tunable from the `CONFIG` table at the top. Leg count is generated rather
than hardcoded, so changing `LEG_COUNT` produces a valid rig immediately.

The one constraint worth knowing: combined limb reach must exceed the rest pose by more
than the body travels between a given leg's steps, or feet drag instead of stepping.

## Why it runs on the client

Procedural animation is cosmetic. Solving six legs every frame on the server would
replicate two CFrame writes per leg per observer and change no gameplay outcome, so each
client builds and drives its own rig. The system is self-contained in one LocalScript.
