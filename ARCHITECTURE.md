# CLAYSTRIKE Architecture Baseline & Standards

> Source of Truth for task **CLAY-001** (Project Setup & Explorer Baseline).

---

## 1. Explorer Hierarchy Contract

All runtime systems, services, controllers, and assets must adhere to this folder structure:

| Service / Parent | Folder Name | ClassName | Purpose |
|---|---|---|---|
| `ReplicatedStorage` | `Shared` | `Folder` | Shared ModuleScripts accessible to both server and client (data models, math, contracts) |
| `ReplicatedStorage` | `Remotes` | `Folder` | Public RemoteEvent and RemoteFunction definitions |
| `ReplicatedStorage` | `Assets` | `Folder` | Visual, audio, and UI assets replicated to clients |
| `ServerStorage` | `EnemyTemplates` | `Folder` | Authoritative enemy models, spawners, and template instances (hidden from client) |
| `ServerScriptService` | `Services` | `Folder` | Authoritative server logic, damage validation, match progression, and session management |
| `StarterPlayer.StarterPlayerScripts` | `Controllers` | `Folder` | Template container for client scripts replicated into `PlayerScripts.Controllers` on join |
| `Workspace` | `CombatArena` | `Folder` | Static play boundary bounds, camera anchors, and play plane markers |
| `Workspace` | `Projectiles` | `Folder` | Active projectile visual models in the workspace |
| `Workspace` | `Enemies` | `Folder` | Active spawned enemy models in the workspace |

---

## 2. Script Naming & Role Conventions

In accordance with Rojo and Roblox conventions:

1. **Server Scripts (`*.server.luau`):**
   - **Location:** `src/server/` (synced to `ServerScriptService.Services`)
   - **Responsibility:** Authoritative game state (damage, enemy health, wave state, player stats, remote validation).
   - **Rule:** Never trust incoming client requests; validate all parameters.

2. **Client LocalScripts (`*.client.luau`):**
   - **Location:** `src/client/` (synced to `StarterPlayer.StarterPlayerScripts.Controllers`)
   - **Responsibility:** Local input handling, viewport camera updates, UI state presentation, local visual/audio feedback.
   - **Rule:** Never calculate authoritative damage or wave completion on the client.

3. **Shared Modules (`*.luau`):**
   - **Location:** `src/shared/` (synced to `ReplicatedStorage.Shared`)
   - **Responsibility:** Pure functions, shared configurations, schema validators, network contracts, and constants.
   - **Rule:** Must be stateless or strictly decoupled between server and client instances.

---

## 3. Explicit Baseline Validation (`Architecture.luau`)

To ensure clean server/client boundaries without cross-contamination:
- `Architecture.ValidateServerBaseline()`: Validates all shared replicated folders, authoritative server storage (`Services`, `EnemyTemplates`), and the `StarterPlayer.StarterPlayerScripts.Controllers` template container.
- `Architecture.ValidateClientBaseline()`: Validates replicated shared folders and verifies the actual running client container (`LocalPlayer.PlayerScripts.Controllers`).

---

## 4. UI and Studio Instance Preservation

- `StarterGui`, `Lighting`, `Workspace.Baseplate`, `Workspace.Terrain`, and custom Studio-placed models remain managed solely within Roblox Studio.
- Rojo only manages the explicitly designated subfolders (`Services`, `Controllers`, `Shared`, `Remotes`, `Assets`, `EnemyTemplates`, and workspace runtime folders).
