# Pass 5 Fix: Angle-Aware Wall Collision (Deflection + Damage)

Date: 2026-02-20
Type: Fix Plan — collision behavior fix
Scope: CollisionHandler.luau only. No config changes, no new files.

---

## Root Cause

`CollisionHandler.checkObstacles` (lines 85-108) ignores impact angle.

**Velocity response (lines 106-107):**
```lua
local bounceVelocity = forwardDir * (-forwardSpeed * state.config.collisionBounce)
state.velocity = Vector3.new(bounceVelocity.X, state.velocity.Y, bounceVelocity.Z)
```
Replaces the entire horizontal velocity with a small backward push. A 5-degree graze at 100 studs/s kills all 100 studs/s of speed instead of preserving the 99.6 studs/s tangential component.

**Damage computation (line 85):**
```lua
local impactSpeed = forwardSpeed
```
Uses full forward speed for damage regardless of angle. A graze at 120 studs/s deals `(120-60) * 1.2 = 72` damage — lethal on a 100 HP vehicle — even though the actual into-wall speed is only ~10 studs/s.

Note: `checkVehicleCollisions` (lines 135-145) already does this correctly — it uses `relativeVelocity:Dot(normal)` for the approach speed and applies impulse along the collision normal. Only `checkObstacles` is broken.

---

## File(s)

`projects/combat-framework/src/Server/Vehicles/CollisionHandler.luau`

---

## Change

**Replace lines 85-108** (everything from `local impactSpeed = forwardSpeed` through `break`) with angle-aware reflection:

```lua
			-- Compute horizontal wall normal for reflection
			local wallNormal = Vector3.new(hit.Normal.X, 0, hit.Normal.Z)
			if wallNormal.Magnitude <= 1e-4 then
				wallNormal = -forwardDir
			else
				wallNormal = wallNormal.Unit
			end

			-- Into-wall speed: component of velocity moving into the wall surface
			-- wallNormal is horizontal (Y=0), so this only considers horizontal velocity
			local intoWallSpeed = -state.velocity:Dot(wallNormal)
			if intoWallSpeed <= 0 then
				-- Moving away from or parallel to wall — no response needed
				continue
			end

			-- Damage based on into-wall speed, not full forward speed
			if intoWallSpeed > state.config.collisionDamageThreshold then
				local canApplyDamage = state.driver ~= nil or math.abs(state.inputThrottle) > 0.01
				if canApplyDamage then
					local damage = math.floor(
						(intoWallSpeed - state.config.collisionDamageThreshold) * state.config.collisionDamageScale + 0.5
					)
					if damage > 0 then
						HealthManager.applyDamage(state.entityId, damage, "impact", "", state.primaryPart.Position, true)
						print(
							string.format(
								"[P5_COLLISION] vehicleId=%s intoWallSpeed=%.1f damage=%d angle=%.0f",
								state.vehicleId,
								intoWallSpeed,
								damage,
								math.deg(math.acos(math.clamp(-forwardDir:Dot(wallNormal), -1, 1)))
							)
						)
					end
				end
			end

			-- Reflect: remove into-wall component + add bounce, preserve tangential speed
			-- wallNormal is horizontal, so this only modifies X/Z — vertical velocity is untouched
			state.velocity += wallNormal * intoWallSpeed * (1 + state.config.collisionBounce)
			break
```

---

## Why

The reflection formula `velocity += wallNormal * intoWallSpeed * (1 + bounce)` is standard game collision physics:

1. `intoWallSpeed = -velocity:Dot(wallNormal)` extracts how fast you're moving into the wall.
2. Adding `wallNormal * intoWallSpeed` cancels the into-wall component (velocity now tangent to wall).
3. Adding `wallNormal * intoWallSpeed * bounce` pushes you away from the wall (bounce-back).
4. Everything not in the wall-normal direction (tangential speed) is preserved untouched.

**Examples at max speed (120 studs/s), collisionBounce = 0.2, threshold = 60:**

| Angle | Into-wall speed | Damage | Speed kept | Behavior |
|-------|----------------|--------|------------|----------|
| 5° graze | 10.5 | 0 | ~119 | Deflect, keep going |
| 15° clip | 31 | 0 | ~115 | Deflect, minor slowdown |
| 30° hit | 60 | 0 | ~104 | Deflect, on the threshold edge |
| 45° slam | 85 | 30 | ~85 | Significant deflection + damage |
| 90° head-on | 120 | 72 | 24 (bounce) | Near-lethal, hard stop |

The `continue` on `intoWallSpeed <= 0` (instead of `break`) allows the loop to check remaining rays if the first hit turns out to be on a surface the vehicle is already moving away from.

---

## Retest

**Test 1 — Graze preserves speed:**
- Setup: Drive at ~100 studs/s along a wall
- Action: Steer slightly into the wall (shallow angle, <15°)
- PASS if: vehicle deflects off wall, `[P5_SPEED]` shows speed stays above 90 studs/s, no `[P5_COLLISION]` print (no damage)
- FAIL if: vehicle stops dead, or `[P5_COLLISION]` prints with high damage on a graze

**Test 2 — Head-on still punishes:**
- Setup: Drive at ~100 studs/s directly at a wall
- Action: Hit wall head-on (near 90°)
- PASS if: `[P5_COLLISION]` prints with `intoWallSpeed` close to 100 and `angle` close to 0, vehicle stops and takes significant damage
- FAIL if: vehicle passes through wall, or takes no damage on head-on

**Test 3 — Moderate angle deflection:**
- Setup: Drive at ~100 studs/s, approach wall at ~30-45°
- Action: Hit wall
- PASS if: vehicle deflects along wall, loses some speed but keeps moving, moderate or no damage depending on exact angle
- FAIL if: full momentum loss or lethal damage at 30°

**Test 4 — No explosion from grazes:**
- Setup: Drive at max speed (~120 studs/s), light_speeder has 100 HP
- Action: Graze a wall at acute angle (<20°)
- PASS if: vehicle survives with full or near-full HP
- FAIL if: vehicle is destroyed from a graze

**Test 5 — Physics stability:**
- Setup: Drive along a wall, maintaining slight pressure into it
- Action: Slide along wall for 3+ seconds
- PASS if: vehicle slides smoothly without jittering, getting stuck, or phasing through
- FAIL if: vehicle vibrates, clips into wall, or gets trapped
