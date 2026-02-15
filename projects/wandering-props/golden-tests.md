# Golden Tests: Wandering Props

Accumulating test scenarios from all passes. Each pass adds tests and lists regressions to re-run.

---

## Pass 1: Bare Bones Core Loop

### Test 1: Basic Spawn-Walk-Despawn Cycle
- **Setup:** Waypoint graph with 2 spawn nodes, 4 waypoint nodes, 2 despawn nodes, connected in a simple chain. 3 NPC models in WanderingPropModels. Config: MaxPopulation = 5, SpawnInterval = 1, DiagnosticsEnabled = true.
- **Action:** Start the server. Wait 10 seconds.
- **Expected:** 5 NPCs appear over the first few seconds, walk along the waypoint chain, and despawn at despawn nodes. As NPCs despawn, new ones spawn to maintain population of 5.
- **Pass condition:** Visual: NPCs walk smoothly along the waypoint path without floating or clipping through ground. Diagnostics: SPAWN and DESPAWN are healthy; no SPAWN_FAIL errors.

### Test 2: Late-Join Sync
- **Setup:** Same waypoint graph as Test 1. Config: MaxPopulation = 10.
- **Action:** Start server. Wait 15 seconds for NPCs to be mid-route. Join with a second client.
- **Expected:** Second client immediately sees all active NPCs at their current mid-route positions. NPCs continue walking from synced positions.
- **Pass condition:** Visual parity between clients is approximately correct. Diagnostics: BULK_SYNC fires with expected count.

### Test 3: Walk Speed Variation and Ground Snap
- **Setup:** Waypoint graph with a sloped ramp between two nodes. Config: BaseWalkSpeed = 8, WalkSpeedVariation = 3, MaxPopulation = 10.
- **Action:** Start server. Observe NPCs walking over the ramp section.
- **Expected:** NPCs walk at visibly different speeds and stay grounded on slope transitions.
- **Pass condition:** No obvious floating/clipping. Movement and animation speed feel coherent.

### Regression Tests
None (first pass).

---

## Pass 2: Points of Interest

### Test 4: Scenic POI Visit
- **Setup:** Waypoint graph with spawn, 3 waypoints, despawn. One Scenic POI linked to middle waypoint, with a ViewZone part offset to one side. Config: MaxPopulation = 3, ScenicDwellMin = 5, ScenicDwellMax = 5, DiagnosticsEnabled = true.
- **Action:** Start server. Wait for NPC to reach Scenic POI waypoint.
- **Expected:** NPC stops, faces ViewZone, idles for dwell duration, then resumes route.
- **Pass condition:** Scenic dwell and facing behavior are correct; POI_ROUTE diagnostics are present.

### Test 5: Social POI Sit and Walk In/Out
- **Setup:** One Social POI linked to a route waypoint, with 2 groups of 2 seats (4 total). Config: MaxPopulation = 5, SocialDwellMin = 8, SocialDwellMax = 8, SocialCapacityPercent = 0.75, SitAnimationId set.
- **Action:** Start server. Observe multiple NPCs at social stop.
- **Expected:** NPCs walk to seats, sit for dwell, then walk back out to route. Capacity cap is respected.
- **Pass condition:** No seat teleport for normal flow; seat claim/release behavior is consistent.

### Test 6: Busy POI Walk-Through
- **Setup:** Route includes one Busy POI.
- **Action:** Start server. Observe NPCs passing Busy POI.
- **Expected:** NPCs do not dwell at Busy POI.
- **Pass condition:** Continuous walk-through behavior.

### Test 7: Stuck NPC Fallback
- **Setup:** One POI is unreachable from spawn path; others are reachable.
- **Action:** Start server and observe route creation.
- **Expected:** Unreachable POI is dropped; NPC still gets valid fallback route.
- **Pass condition:** POI_SKIP/no_path diagnostics appear; NPCs still complete routes.

### Test 8: Late-Join with POI State
- **Setup:** Scenic/Social POIs active with dwell times > 0.
- **Action:** Join second client while NPCs are mid-route and mid-dwell.
- **Expected:** Late join reproduces current state (walking, scenic dwell, or social sit) correctly.
- **Pass condition:** No major state desync on join.

### Regression Tests
Re-run from Pass 1:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 3: Walk Speed Variation and Ground Snap**

---

## Pass 3: Zones + Clock Hook + Night Drain

### Test 9: Zone Waypoint Variation
- **Setup:** Route with spawn, 2 zone waypoints (`Zone=true`, e.g. Size 30x1x30), 1 spot waypoint, despawn. Diagnostics on.
- **Action:** Start server and observe multiple NPCs.
- **Expected:** Zone waypoints produce spread-out positions; spot waypoint remains converged.
- **Pass condition:** Clear spatial variation at zone nodes and stable spot behavior.

### Test 10: Scenic POI Stand-Point Variation
- **Setup:** Scenic POI with internal `Waypoint` part sized as a small area (not a single point), valid link to graph, ViewZone present.
- **Action:** Observe several NPC visits to the same Scenic POI.
- **Expected:** Scenic NPCs stand at different points on that Scenic waypoint area while still performing scenic dwell/facing.
- **Pass condition:** No center-only clustering when internal Scenic waypoint area is used.

### Test 11: Clock-Based Day/Night Hook
- **Setup:** Config: `DayNightEnabled=true`, `NightStartHour=19`, `DayStartHour=6`, `NightPopulationMultiplier=0.3`, `SpawnInterval=1`, diagnostics on.
- **Action:** Set `Lighting.ClockTime` to day (e.g. 12) and let population fill. Then set to night (e.g. 22). Later set back to day (e.g. 8).
- **Expected:** System reads clock time directly. Night lowers effective cap; day restores it.
- **Pass condition:** `DAYNIGHT_CHANGE` diagnostics appear on transitions and active population follows cap behavior.

### Test 12: Night Drain Route Shortening (Despawn-Point Safe)
- **Setup:** Enable `NightDrainEnabled=true`, set low `NightPopulationMultiplier` (e.g. 0.3), with POIs present.
- **Action:** Fill daytime population, then move clock into night window.
- **Expected:** Excess active NPCs get rerouted to short completion paths and despawn via despawn waypoints (not in-place deletion).
- **Pass condition:** Faster nighttime reduction while preserving route-end despawn behavior.

### Test 13: Social Seat Exit During Night Drain
- **Setup:** Night drain enabled and social POIs active.
- **Action:** Trigger night while some NPCs are seated.
- **Expected:** Seated NPCs are not rerouted mid-seat; they stand and walk out naturally before continuing shortened route.
- **Pass condition:** No snap from seat to social waypoint during seat-exit flow.

### Test 14: Marker Visibility Toggle
- **Setup:** Run once with `HideMarkersAtRuntime=true`, once with `false`.
- **Action:** Observe waypoint markers, POI waypoint parts, scenic ViewZone helper, and social seat helper parts.
- **Expected:** True = hidden markers. False = visible markers.
- **Pass condition:** Visibility toggles without breaking behavior.

### Regression Tests
Re-run:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**

---

## Pass 4: Optimization (LOD + Pooling)

### Test 15: LOD Tier Visual Transitions
- **Setup:** Waypoint graph spanning a large area (>300 studs across). Config: MaxPopulation = 20, LODEnabled = true, LODNearDistance = 50, LODLowDistance = 100, LODMidDistance = 200, DiagnosticsEnabled = true.
- **Action:** Start server. Walk player from one end of the map to the other, moving through clusters of NPCs.
- **Expected:** NPCs near the player walk with full animation. NPCs far away are invisible. As the player moves closer, distant NPCs reappear at their correct route positions with correct animation state. No visual pop-in glitches (NPCs don't appear in wrong positions).
- **Pass condition:** LOD_TRANSITION diagnostics fire as player moves. NPCs restored from far tier are at plausible route positions. No frozen or T-posed NPCs.

### Test 16: Model Pool Reuse
- **Setup:** Config: MaxPopulation = 10, SpawnInterval = 1, PoolEnabled = true, PoolMaxPerModel = 5, DiagnosticsEnabled = true. Use 2 NPC models.
- **Action:** Start server. Wait 60 seconds for several spawn/despawn cycles.
- **Expected:** After the first cycle of despawns, subsequent spawns reuse pooled models. POOL_ACQUIRE diagnostics appear. Model count in memory stays bounded.
- **Pass condition:** POOL_ACQUIRE fires regularly after initial population. No POOL_FULL_DESTROY unless population turnover is very high. NPCs spawned from pool behave identically to cloned NPCs (walk, animate, despawn normally).

### Test 17: LOD + POI State Consistency
- **Setup:** Route includes Scenic and Social POIs. Config: MaxPopulation = 10, LODEnabled = true, LODMidDistance = 30 (short, to trigger far tier easily).
- **Action:** Start server. Walk player far away so NPCs enter far tier while some are dwelling or sitting. Walk back.
- **Expected:** NPCs restored from far tier are in correct state: if dwell/sit time not expired, they appear dwelling/sitting; if expired, they appear walking past the POI.
- **Pass condition:** No NPC is frozen at a POI they should have left. No NPC skips a POI they should be at. Seat animations play correctly after restoration.

### Test 18: LOD Disabled Regression
- **Setup:** Config: LODEnabled = false, PoolEnabled = false, MaxPopulation = 20.
- **Action:** Run all Pass 1-3 golden tests.
- **Expected:** All behavior is identical to pre-Pass-4.
- **Pass condition:** No regressions when optimization features are disabled.

### Regression Tests
Re-run from previous passes:
- **Test 1: Basic Spawn-Walk-Despawn Cycle**
- **Test 2: Late-Join Sync**
- **Test 4: Scenic POI Visit**
- **Test 5: Social POI Sit and Walk In/Out**
- **Test 9: Zone Waypoint Variation**
- **Test 11: Clock-Based Day/Night Hook**
- **Test 12: Night Drain Route Shortening**
- **Test 13: Social Seat Exit During Night Drain**
