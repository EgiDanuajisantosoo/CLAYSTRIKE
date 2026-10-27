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
      clientTimestamp: number,   -- Client os.clock() timestamp for interpolation/latency compensation
      moveDirection: Vector2,    -- Normalized movement input vector (|v| <= 1.0)
  }
  ```
- **Authoritative Resolution:**
  - Client does **not** transmit position coordinates.
  - The server holds the authoritative aircraft position and computes position delta based on `moveDirection`, `GameConfig.Movement.MaxSpeed`, `deltaTime`, and enforces `GameConfig.Arena` boundaries.
- **Validation Rules:**
  - Whitelist key check: Any unrecognized or client-claimed position field results in immediate rejection.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - `moveDirection.Magnitude` must be $\le 1.05$.

---

### `FireWeapon`
- **Direction:** `Client -> Server`
- **Purpose:** Requests a weapon discharge **intent**.
- **Payload Schema:**
  ```luau
  {
      contractVersion: string,   -- Must match GameConfig.CONTRACT_VERSION ("1.0.0")
      clientTimestamp: number,   -- Client os.clock() timestamp
      weaponId: string,          -- Identifier matching WeaponConfig.Weapons (e.g. "StandardPeaShooter")
      aimDirection: Vector2,     -- Desired firing direction vector (|v| > 0)
  }
  ```
- **Authoritative Resolution:**
  - Client does **not** transmit the firing origin.
  - The server derives firing origin from the authoritative position/attachment points of the player's aircraft model.
  - The server checks whether `weaponId` matches the player's active weapon, verifies cooldown, and authoritatively spawns projectiles and evaluates damage.
- **Validation Rules:**
  - Whitelist key check: Forbidden fields (e.g., `damage`, `enemyHealth`, `origin`, `reward`) are rejected immediately.
  - Numbers must be finite (not `NaN`, `math.huge`, or `-math.huge`).
  - `weaponId` must exist in `WeaponConfig.Weapons`.
  - `aimDirection` must have magnitude $> 0.001$.

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
5. **Contract Versioning & Strict Instance Check:**
   - All network events carry `contractVersion` (`GameConfig.CONTRACT_VERSION = "1.0.0"`).
   - Remote instances under `ReplicatedStorage.Remotes` are verified with `IsA("RemoteEvent")`. Conflicting ClassNames halt initialization with an explicit error.
6. **Halt-on-Failure Bootstrap Policy:**
   - If Explorer baseline validation or contract unit tests fail, the server immediately halts via `error()`, preventing insecure or corrupted network listeners from starting.
