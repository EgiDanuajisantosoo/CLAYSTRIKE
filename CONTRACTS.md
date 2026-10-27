# CLAYSTRIKE Network Contracts & Shared Config Specification

> Source of truth for task **CLAY-002** (Define Remote Contracts & Shared Config).

---

## 1. RemoteEvent Payload Contracts

All network communication between client and server occurs through strongly-typed contracts defined in `ReplicatedStorage.Shared.RemoteContracts`.

### `MovePlane`
- **Direction:** `Client -> Server`
- **Purpose:** Transmits player movement **intent** within the 2.5D plane.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      clientTimestamp: number,   -- Client os.clock() timestamp (informational only; never trusted for authority)
      moveDirection: Vector2,    -- Normalized movement input vector (|v| <= 1.05)
  }
  ```
- **Authoritative Resolution:**
  - Client does **not** transmit position coordinates.
  - The server holds the authoritative aircraft position and computes position delta based on `moveDirection`, `GameConfig.Movement.MaxSpeed`, `deltaTime`, and enforces `GameConfig.Arena` boundaries.
- **Validation Rules:**
  - Whitelist key check: Any unrecognized or client-claimed position field results in immediate rejection.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - `moveDirection.Magnitude` must be $\le 1.05$ (allowing a uniform 5% margin for analog thumbstick diagonal tolerances).

---

### `FireWeapon`
- **Direction:** `Client -> Server`
- **Purpose:** Requests a weapon discharge **intent**.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      clientTimestamp: number,   -- Client os.clock() timestamp (informational only; never trusted for authority)
      weaponId: string,          -- Identifier matching WeaponConfig.Weapons (e.g. "StandardPeaShooter")
      aimDirection: Vector2,     -- Desired firing direction vector (0.001 <= |v| <= 1.05)
  }
  ```
- **Authoritative Resolution:**
  - Client does **not** transmit the firing origin.
  - The server derives firing origin from the authoritative position/attachment points of the player's aircraft model.
  - The server normalizes `aimDirection.Unit` before spawning projectiles, preventing raw vector magnitudes from altering projectile physics.
  - The server checks whether `weaponId` matches the player's active weapon, verifies cooldown, and authoritatively spawns projectiles and evaluates damage.
- **Validation Rules:**
  - Whitelist key check: Forbidden fields (e.g., `damage`, `enemyHealth`, `origin`, `reward`) are rejected immediately.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - `weaponId` must exist in `WeaponConfig.Weapons`.
  - `aimDirection.Magnitude` must satisfy $0.001 \le |v| \le 1.05$.

---

### `GameStateChanged`
- **Direction:** `Server -> Client`
- **Purpose:** Replicates session and match state transitions with strictly-typed metadata.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      serverTimestamp: number,   -- Server os.clock() timestamp
      state: string,             -- Member of GameConfig.GameStates ("Lobby", "WaveActive", etc.)
      details: { [string]: any }?-- Strongly-validated metadata dictionary (max 5 keys)
  }
  ```
- **Per-State Details Schema:**
  - **`Lobby`**: `{ countdown: number? }` (countdown must be finite $\ge 0$)
  - **`WaveActive`**: `{ waveNumber: number, remainingEnemies: number }` (both must be finite non-negative integers; `waveNumber >= 1`)
  - **`Intermission`**: `{ countdown: number, nextWave: number }` (`nextWave >= 1` integer)
  - **`BossPhase`**: `{ bossName: string, phaseNumber: number }` (`bossName` 1-50 chars; `phaseNumber >= 1` integer)
  - **`MissionSuccess`**: `{ totalWaves: number, missionDuration: number }` (`totalWaves >= 1` integer; `missionDuration >= 0`)
  - **`MissionFailed`**: `{ waveReached: number, failureReason: string }` (`waveReached >= 1` integer; `failureReason` 1-100 chars)

---

## 2. Security & Authority Boundaries

1. **Separation of Config from Authority:**
   - `WeaponConfig` defines base damage and cooldown values for client prediction, HUD presentation, and UI.
   - The server is the **sole authority** determining whether a shot is permitted, when cooldown expires, and how much damage is applied. Client-submitted numbers are never trusted for game state changes.
2. **Client Timestamps Not Trusted for Authority:**
   - `clientTimestamp` is included purely for client-side visual interpolation and timeline reconciliation.
   - The server **never** trusts `clientTimestamp` for weapon cooldowns, rate limits, or authoritative gameplay timelines; server `os.clock()` is always authoritative.
3. **Explicit Whitelist Schema:**
   - Any client payload containing fields outside the specified schema is rejected immediately.
4. **Finite Value Verification:**
   - All numerical values (`X`, `Y`, timestamps) must pass finite validation. `NaN`, `math.huge`, and `-math.huge` are strictly forbidden.
5. **Fail-Closed Per-Player Rate Limiting:**
   - `RateLimiter` on the server enforces token bucket limits:
     - `MovePlane`: 30 requests/sec with burst allowance of 5.
     - `FireWeapon`: 12 requests/sec with burst allowance of 3.
   - **Fail-Closed Policy:** Any remote call lacking an explicit rule in `GameConfig.NetworkRateLimits` is rejected immediately.
   - Limit state is stored purely in server memory and cleaned up when players leave.
6. **Contract Versioning & Strict Instance Check:**
   - All network events carry `contractVersion` (`GameConfig.CONTRACT_VERSION = "1.0.0"`).
   - Both server and client verify that instances under `ReplicatedStorage.Remotes` are strictly `IsA("RemoteEvent")`. Conflicting ClassNames halt initialization with an explicit error.
7. **Halt-on-Failure Bootstrap Policy:**
   - Server bootstrap strictly validates baseline folders and runs 23 contract unit tests **before** creating or binding network listeners. Any failure triggers `error()`, completely halting network initialization.
