# CLAYSTRIKE — Asset Import & Performance Standards

> Standardized specifications, budgets, validation rules, and review checklists for importing 3D models and clay visual assets into Roblox Studio.
> Source Task: `CLAY-048` (Execution Order 32). Conforms to `CLAY-026` (Style Guide) and `CLAYSTRIKE Master Development Plan`.

---

## 1. Scope & Objective

This document governs all 3D assets imported or procedurally constructed for **CLAYSTRIKE**, including player aircraft, enemy archetypes, boss phases, projectiles, and parallax scenery layers.

The primary goals are:
1. **Multiplayer Co-op Scalability:** 1–4 players, 20+ simultaneous enemies, and high-cadence projectile sweeps without frame drops, physics hitching, or memory bloat.
2. **Authoritative Hitbox Isolation:** Complete separation between collision query geometry and high-detail visual render geometry.
3. **Claymation Aesthetic Consistency:** Tactile, hand-molded clay silhouettes with stop-motion charm, matte surfaces, and zero distracting shader/specular glare.
4. **Clean Provenance:** 100% original designs with clear authorship, licensing, and usage rights.

---

## 2. Model Structure & Technical Contracts

Every vehicle or character model MUST conform to the following hierarchy:

```text
Model: [ModelName]
├── RootPart / HitProxy (BasePart) [PrimaryPart]
│   ├── WeldConstraint (to VisualSubpart1)
│   ├── WeldConstraint (to VisualSubpart2)
│   ├── Attachment: Center (Pivot centroid at 0, 0, 0)
│   ├── Attachment: Muzzle (Firing origin: +X for player, -X for shooting enemy)
│   └── Attachment: Exhaust (Thruster origin: -X for player)
├── VisualSubpart1 (BasePart or MeshPart)
├── VisualSubpart2 (BasePart or MeshPart)
└── ...
```

### 2.1 Collision Proxy Rules (Non-Negotiable)

| Part Role | Name | CanCollide | CanTouch | CanQuery | CastShadow | Anchored |
| :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **PrimaryPart (Player)** | `RootPart` | `false` | `false` | `true` | `true` | `true` |
| **PrimaryPart (Enemy)** | `HitProxy` | `false` | `false` | `true` | `true` | `true` |
| **Visual Render Parts** | Any descriptive name | `false` | `false` | `false` | `true` | `true` |

- **Why `CanCollide = false`?** In a 2.5D side-scroller with server-authoritative raycast sweeps, physics collisions between parts cause severe physics engine overhead and potential clipping glitches.
- **Why `CanQuery = true` on RootPart/HitProxy only?** Swept raycasts for projectiles (`RaycastParams`) only need to intersect a single standardized box proxy per entity, making hit detection instant ($O(1)$) and immune to fine surface variations.
- **Why `CanQuery = false` on all visual parts?** Prevents raycast fragmentation and ensures projectiles cannot falsely register multiple hits on wingtips or antennas.

### 2.2 Orientation & Pivot Conventions

CLAYSTRIKE uses a **2.5D Side-Scrolling Coordinate System**:
- **Flight Axis (Horizontal):** X axis.
  - **Player Aircraft:** Forward flight vector faces **`+X`** (`LookVector.X >= 0.99`).
  - **Enemies:** Flight vector faces **`-X`** (`LookVector.X <= -0.99` or visual features point towards player at `-X`).
- **Altitude Axis (Vertical):** Y axis. Up is **`+Y`** (`UpVector.Y >= 0.99`).
- **Depth Axis (Side-Scroller Plane):** Z axis. Fixed to `Arena.PlayPlaneZ` (typically `Z = 0`).

---

## 3. Geometry & Budget Limits

| Asset Category | Max Parts | Max Triangles (Mesh) | Collision Proxy Size (X, Y, Z) | Texture Budget |
| :--- | :--- | :--- | :--- | :--- |
| **Player Aircraft** | 12 parts | 3,500 tris | `(4.2, 1.2, 1.2)` | 1024x1024 diffuse map (or vertex colors) |
| **Enemy Drone (Flyer)** | 8 parts | 1,800 tris | `(3.0, 2.0, 2.0)` | 512x512 diffuse map |
| **Enemy Interceptor (Pursuer)**| 8 parts | 2,200 tris | `(3.5, 2.4, 2.4)` | 512x512 diffuse map |
| **Enemy Gunship (Turret)** | 10 parts | 2,800 tris | `(4.2, 3.0, 3.0)` | 512x512 diffuse map |
| **Boss Ship (Per Phase)** | 20 parts | 6,500 tris | `(12.0, 8.0, 6.0)` | 1024x1024 diffuse map |
| **Parallax Scenery Piece** | 6 parts | 1,200 tris | Non-colliding | 512x512 diffuse map |

---

## 4. Materials, Shaders, & Lighting

1. **Material:** Use `Enum.Material.SmoothPlastic` or custom matte clay SurfaceAppearance.
2. **Roughness & Metalness:**
   - Clay surfaces: Roughness `0.65 – 0.85`, Metalness `0.00 – 0.05`.
   - Glazed enamel accents (cockpit, sensors): Roughness `0.20 – 0.35`, Metalness `0.10`.
3. **No Heavy Custom Shaders:** Keep models performant on mobile and low-end hardware.
4. **CastShadow:** Set to `true` on visual parts to leverage soft studio clay shadows without lag.

---

## 5. Review Checklist for Imported Assets

Before integrating any 3D asset into `ServerStorage.EnemyTemplates` or client character controllers:

- [ ] **1. Model Naming:** Follows canonical convention (`Plane_<UserId>`, `StraightFlyerTemplate`, etc.).
- [ ] **2. PrimaryPart Assigned:** PrimaryPart is set to `RootPart` or `HitProxy`.
- [ ] **3. Orientation Verified:** Correct forward vector along +X (Player) or -X (Enemy).
- [ ] **4. Collision Proxy Compliant:** PrimaryPart is the ONLY queryable part; all visual parts have `CanCollide = false`, `CanTouch = false`, `CanQuery = false`.
- [ ] **5. Welds Complete:** Every non-primary part has a `WeldConstraint` rooted to the PrimaryPart. Zero unanchored or dangling parts.
- [ ] **6. Required Attachments:**
  - `Center` attachment exists at centroid `(0, 0, 0)`.
  - `Muzzle` attachment exists at weapon muzzle tip.
  - `Exhaust` attachment exists on engine cowlings.
- [ ] **7. Budget Compliant:** Total parts <= category limit; mesh polygon count within limits.
- [ ] **8. Contrast & Readability:** Silhouette is readable at 2.5D camera distance against backgrounds.
- [ ] **9. Provenance Recorded:** 100% original asset; recorded in Section 6.

---

## 6. Asset Provenance & Licensing Register

All assets in CLAYSTRIKE are originally authored for this project.

| Asset ID | Asset Name | Author / Source | License / Rights | Status |
| :--- | :--- | :--- | :--- | :--- |
| `ASSET-PLA-01` | ClayFalcon Player Aircraft | CLAYSTRIKE Team | 100% Original / Proprietary | Production (CLAY-027) |
| `ASSET-ENM-01` | Clay Drone (StraightFlyer) | CLAYSTRIKE Team | 100% Original / Proprietary | Production (CLAY-028) |
| `ASSET-ENM-02` | Clay Interceptor (Pursuer) | CLAYSTRIKE Team | 100% Original / Proprietary | Production (CLAY-028) |
| `ASSET-ENM-03` | Clay Gunship (TurretShooter) | CLAYSTRIKE Team | 100% Original / Proprietary | Production (CLAY-028) |
| `ASSET-ENV-01` | Clay Dunes & Sandstone Pillars| CLAYSTRIKE Team | 100% Original / Proprietary | Production (CLAY-032) |
