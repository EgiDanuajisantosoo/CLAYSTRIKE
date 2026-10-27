# CLAYSTRIKE — Visual Style Guide

> **Document Status:** Authoritative Art Direction Standard  
> **Task:** CLAY-026 (`art/visual-style-guide`)  
> **Target Aesthetic:** Hybrid Claymation Forms + Modern Readable VFX  
> **Platform Target:** Roblox 2.5D Side-Scrolling Co-op Arcade Shooter

---

## 1. Product Vision & Visual Identity

CLAYSTRIKE combines the tactile, charming, handmade feel of **claymation / plasticine sculpture** with the crisp readability, snappy responsiveness, and high contrast of a **modern arcade shooter**.

### Key Aesthetic Pillars:
1. **Tactile Form (Plasticine Soul):**
   - Softened corners, chunky bevels, and subtle organic imperfections.
   - Non-glossy, matte clay textures (`SmoothPlastic` with low specular reflection, or custom matte PBR).
   - Avoid razor-sharp, photorealistic hard-surface geometry.
2. **Modern VFX (Readability First):**
   - Clean, high-contrast, uncluttered particle bursts and muzzle flashes.
   - Short particle lifetimes ($\le 0.35$ seconds) to avoid obscuring gameplay.
   - Restrained bloom and additive glow so bullet trajectories, enemy telegraphs, and play boundaries are unmistakably clear.
3. **Layered Depth Separation:**
   - Foreground gameplay plane ($Z = 0$): vibrant, saturated, highest contrast.
   - Middleground parallax ($Z = -25$ to $-60$): desaturated earthy tones.
   - Background sky ($Z < -100$): soft pastel gradients with low contrast.
4. **Strict Originality Guardrails:**
   - All silhouettes, model proportions, vehicle shapes, and visual motifs are original.
   - Do **NOT** copy, mimic, or import proprietary assets or character designs from *Platypus* or other IP. Genre inspiration is restricted to mechanical arcade conventions only.

---

## 2. Silhouette Language & Proportions

| Category | Silhouette Characteristics | Proportions | Visual Role |
|---|---|---|---|
| **Player Aircraft** | Chunky delta/biplane wings, bulbous clay canopy, soft rounded nose. Forward-tilted cockpit. | Length: 10–14 studs, Wingspan: 8–12 studs, Height: 3–5 studs. | Instant hero focal point; distinct facing arrow pointing right (+X). |
| **Enemy Archetype A (Straight Flyer)** | Dart/wedge shape, tapered rear, single blunt engine cowl. | Length: 6–8 studs, Wingspan: 5–7 studs. | Fast, disposable drone; simple read from peripheral vision. |
| **Enemy Archetype B (Pursuer)** | Beetle/wasp curved fuselage, twin organic nacelles. | Length: 8–10 studs, Wingspan: 7–9 studs. | Aggressive, predatory; angled forward wings. |
| **Enemy Archetype C (Turret Shooter)** | Rounded hemispherical hull, visible top/bottom rotating clay turrets. | Diameter: 10–12 studs, Height: 6–8 studs. | Heavy, fortified silhouette; distinct weapon ports. |
| **Boss (Multi-Phase)** | Massive segmented modular clay dreadnought/golem; distinct breakable components. | Length: 30–45 studs, Height: 20–30 studs. | Dominant screen presence; clear telegraphing weak points. |

---

## 3. Color Palette & Material Standards

### A. Authoritative Color Hierarchy
- **Player Colors (Co-op P1–P4):**
  - Player 1: Crimson Clay (`Color3.fromRGB(215, 60, 50)`)
  - Player 2: Cobalt Clay (`Color3.fromRGB(45, 120, 215)`)
  - Player 3: Ochre Amber (`Color3.fromRGB(225, 170, 40)`)
  - Player 4: Jade Mint (`Color3.fromRGB(50, 185, 110)`)
- **Player Projectiles:**
  - Standard Bullet: High-vis Lemon Gold (`Color3.fromRGB(255, 235, 75)`)
  - Spread Pellet: Electric Cyan (`Color3.fromRGB(80, 225, 255)`)
- **Enemy Colors:**
  - Common Hull: Rust Purple (`Color3.fromRGB(110, 65, 95)`) & Olive Clay (`Color3.fromRGB(95, 110, 65)`)
  - Elite / Armored: Slate Obsidian (`Color3.fromRGB(50, 45, 55)`)
  - Enemy Bullets: Warning Coral / Neon Magenta (`Color3.fromRGB(255, 60, 90)`) with high luminance contrast against background.
- **Environment Palette:**
  - Near Clouds ($Z = -25$): Warm Sand (`Color3.fromRGB(180, 160, 145)`)
  - Mid Mountains ($Z = -60$): Earth Umber (`Color3.fromRGB(120, 100, 90)`)
  - Far Skyline ($Z = -110$): Dusty Lavender (`Color3.fromRGB(80, 70, 75)`)

### B. Material & Surface Rules
- Default Part Material: `Enum.Material.SmoothPlastic`.
- Surface Appearance: Low specularity (`Roughness` $\ge 0.6$, `Metalness` $\le 0.1$).
- No glassy, chrome, or mirror-like surfaces on gameplay entities.

---

## 4. Modern VFX Rules (Combat Readability Guarantee)

1. **High Contrast Over High Bloom:**
   - VFX must rely on vivid shape contrast rather than blinding screen-space bloom.
   - Bullet trails: Solid tapered ribbon or discrete clay puff particles; maximum length: 8 studs.
2. **Short Particle Lifetimes:**
   - Muzzle flashes: $\le 0.08$ seconds.
   - Bullet impact sparks / clay splatters: $\le 0.25$ seconds.
   - Enemy explosion bursts: $\le 0.40$ seconds.
   - Residual smoke / dust: strictly semi-transparent (`Transparency` $\ge 0.65$), maximum duration 0.60 seconds.
3. **Screen Visibility Invariant:**
   - At no point during intense combat may particles cover $> 15\%$ of the active screen area.
   - Player aircraft silhouette and enemy bullet projectiles must remain 100% distinguishable at all times.

---

## 5. Lighting Preset Standards

- **Lighting Technology:** `Enum.Technology.Future` (or `ShadowMap` fallback).
- **Ambient:** `Color3.fromRGB(80, 80, 95)` (cool soft fill).
- **OutdoorAmbient:** `Color3.fromRGB(100, 95, 90)`.
- **Brightness:** `1.8` to `2.2` (bright, crisp stop-motion studio look).
- **Sun / Directional Light:**
  - Orientation: Soft 45-degree top-front light (`ClockTime = 14.5`).
  - CastShadows: `true` on gameplay entities; soft rim light accentuating clay bevels.
- **Atmosphere & Bloom:**
  - Bloom Size: $\le 12$, Intensity: $\le 0.4$. Avoid haze that washes out playfield colors.

---

## 6. Objective Review Checklist for Assets

Before committing any 3D model, material, or effect:
- [ ] Silhouette passes 50% scale silhouette test against neutral background.
- [ ] Proportions adhere to designated archetype size table.
- [ ] Material uses matte clay styling (`SmoothPlastic` or low-specular PBR).
- [ ] PrimaryPart is designated, anchored/collision flags match architecture rules (`CanCollide = false` for projectiles/backgrounds).
- [ ] Attachment points (`MuzzlePoint`, `EngineExhaust`, `HitBox`) exist and use standardized names.
- [ ] VFX particle lifetime does not exceed 0.40s.
- [ ] Enemy projectiles contrast strongly against background layers ($Z < 0$).
- [ ] Design is 100% original and verified free of proprietary references.
