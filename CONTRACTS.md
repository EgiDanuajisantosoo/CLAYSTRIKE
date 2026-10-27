# CLAYSTRIKE Network Contracts & Shared Config Specification

> Source of truth for task **CLAY-002** (Define Remote Contracts & Shared Config).

---

## 1. RemoteEvent Payload Contracts

All network communication between client and server occurs through strongly-typed contracts defined in `ReplicatedStorage.Shared.RemoteContracts`.

### `MovePlane`
- **Direction:** `Client -> Server`
- **Purpose:** Transmits player movement intent within the 2.5D plane.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      clientTimestamp: number,   -- Client os.clock() timestamp for interpolation/replay
      position: Vector2,         -- Current reported position on the 2D play plane
      moveDirection: Vector2,    -- Normalized movement input vector (|v| <= 1.0)
  }
  ```
- **Validation Rules:**
  - Whitelist key check: Any unrecognized field results in immediate rejection.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - Position must fall within arena bounds with safety tolerance.
  - `moveDirection.Magnitude` must be $\le 1.05$.

---

### `FireWeapon`
- **Direction:** `Client -> Server`
- **Purpose:** Requests a weapon discharge.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      clientTimestamp: number,   -- Client os.clock() timestamp
      weaponId: string,          -- Identifier matching WeaponConfig.Weapons (e.g. "StandardPeaShooter")
      origin: Vector2,           -- Requested firing origin
      aimDirection: Vector2,     -- Desired firing direction vector (|v| > 0)
  }
  ```
- **Validation Rules:**
  - Whitelist key check: Forbidden fields (e.g., `damage`, `enemyHealth`, `reward`) are rejected immediately.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - `weaponId` must exist in `WeaponConfig.Weapons`.
  - `aimDirection` must have magnitude $> 0.001$.
  - Server authoritatively evaluates weapon cooldown and hit validation.

---

### `GameStateChanged`
- **Direction:** `Server -> Client`
- **Purpose:** Replicates session and match state transitions.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      serverTimestamp: number,   -- Server os.clock() timestamp
      state: string,             -- Member of GameConfig.GameStates ("Lobby", "WaveActive", etc.)
      details: { [string]: any }?-- Optional metadata (e.g. waveNumber, remainingEnemies)
  }
  ```

---

## 2. Security & Authority Boundaries

1. **Separation of Config from Authority:**
   - `WeaponConfig` defines base damage and cooldown values for client prediction, HUD presentation, and UI.
   - The server is the **sole authority** determining whether a shot is permitted, when cooldown expires, and how much damage is applied. Client-submitted numbers are never trusted for game state changes.
2. **Explicit Whitelist Schema:**
   - Any client payload containing fields outside the specified schema is rejected immediately.
3. **Finite Value Verification:**
   - All numerical values (`X`, `Y`, timestamps) must pass finite validation. `NaN`, `math.huge`, and `-math.huge` are strictly forbidden.
4. **Per-Player Rate Limiting:**
   - `RateLimiter` on the server enforces token bucket limits:
     - `MovePlane`: 30 requests/sec with burst allowance of 5.
     - `FireWeapon`: 12 requests/sec with burst allowance of 3.
   - Limit state is stored purely in server memory and cleaned up when players leave.
5. **Contract Versioning:**
   - All network events carry `contractVersion` (`GameConfig.CONTRACT_VERSION = "1.0.0"`).
   - Mismatches are rejected by server validators with security warnings.
