<div align="center">

# 🐕 DogeService

### A server-authoritative profile and data service for Roblox

Save player data. Read profile values. Manage currencies and inventory. Keep clients read-only by default.

[Getting Started](#-getting-started) · [API Reference](#-api-reference) · [Security](#-security-model) · [GitHub Pages](#-publish-the-project-page)

</div>

---

> **Status:** Starter implementation. DogeService is an original project inspired by common Roblox profile-storage patterns; it is not a drop-in replacement for, or a proven improvement over, the established ProfileStore library. Test it thoroughly in a separate Roblox experience before using it for valuable live-game data.

## ✨ Features

- **Persistent profiles** backed by Roblox `DataStoreService`.
- **Server-owned data** with a read-only client API.
- **Automatic loading** when players join, plus an included bootstrap Script.
- **Autosaving and session leases** to reduce overlapping profile sessions and accidental data loss.
- **Safe path access** such as `"Currency.Coins"` and numeric indexes using path tables.
- **Inventory helpers** to add, remove, count, and check item quantities.
- **Template reconciliation** so new default fields can be added to existing profiles.
- **Client snapshots and updates** for UI such as currency labels and inventory displays.
- **Validation** for serializable values, invalid numbers, cyclic tables, and oversized profiles.
- **Manual save and release methods** when your game needs them.

## 📦 Project structure

```text
DogeService/
├── DogeService.luau                   # Public module: server/client facade
├── DogeServiceServer.luau             # Server profile implementation
├── DogeServiceBootstrap.server.luau   # Starts DogeService
├── README.md                          # This guide
└── docs/
    └── index.html                    # GitHub Pages project site
```

## 🚀 Getting started

### 1. Add the scripts in Roblox Studio

Create these instances and paste in the matching file contents:

| Roblox location | Instance type | Name | Source file |
| --- | --- | --- | --- |
| `ReplicatedStorage` | ModuleScript | `DogeService` | `DogeService.luau` |
| `ServerScriptService` | ModuleScript | `DogeServiceServer` | `DogeServiceServer.luau` |
| `ServerScriptService` | Script | `DogeServiceBootstrap` | `DogeServiceBootstrap.server.luau` |

The bootstrap calls `DogeService:Start()`. The server module creates `ReplicatedStorage.DogeServiceRemotes` automatically. **Do not manually create or modify those remotes.**

### 2. Enable DataStore access for testing

Publish a separate test experience, then in Roblox Studio open **Game Settings → Security** and enable **Enable Studio Access to API Services** for that test experience. Be careful: Studio may access the same DataStores as the published experience when API access is enabled. Use a separate test experience to avoid changing live player data.

### 3. Read and edit a profile on the server

The bootstrap loads profiles automatically, so call `WaitForProfile` to wait for that existing load. Do not start a second profile loader.

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DogeService = require(ReplicatedStorage:WaitForChild("DogeService"))

Players.PlayerAdded:Connect(function(player)
    local profile, err = DogeService:WaitForProfile(player, 20)
    if not profile then
        warn("Profile did not load:", err)
        return
    end

    print("Profile owner:", profile.Name, profile.UserId)
    print("Coins:", profile:Get("Currency.Coins", 0))

    profile:Increment("Currency.Coins", 25)
    profile:AddItem("Apple", 3)

    print("Inventory:", profile:GetInventory())
end)
```

### 4. Read a profile on the client

Use this in a `LocalScript`, for example under `StarterPlayerScripts`. The client gets a **snapshot**, not a live mutable server object.

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local DogeService = require(ReplicatedStorage:WaitForChild("DogeService"))

local profile, err = DogeService:WaitForProfile(20)
if not profile then
    warn("Profile did not load:", err)
    return
end

print("Player:", profile.Name)
print("User ID:", profile.UserId)
print("Coins:", DogeService:GetValue("Currency.Coins", 0))
print("Inventory:", DogeService:GetInventory())

DogeService.ProfileUpdated:Connect(function(updatedProfile)
    if updatedProfile then
        print("Profile changed. Coins:", updatedProfile.Data.Currency.Coins)
    end
end)
```

### 5. Customize the profile template

Edit `DogeService.Template` in `DogeServiceServer.luau` before the bootstrap starts. Example default data:

```lua
Template = {
    SchemaVersion = 1,
    CreatedAt = 0,
    LastJoinedAt = 0,
    Currency = {
        Coins = 0,
        Gems = 0,
    },
    Stats = {
        Level = 1,
        XP = 0,
        TotalPlaytime = 0,
    },
    Inventory = {}, -- Example: { Apple = 5, Sword = 1 }
    Equipped = {},
    Settings = {
        Music = true,
        SoundEffects = true,
    },
}
```

Existing profiles are reconciled with missing defaults on load. Keep saved data serializable: strings, finite numbers, booleans, and supported tables. Do not store Instances, functions, connections, userdata, cyclic tables, or mixed array/dictionary tables.

## 🧰 API reference

### Server module

Require `DogeService` from a server Script. The public module routes server calls to the implementation in `ServerScriptService`.

| Method | Purpose |
| --- | --- |
| `DogeService:Start()` | Initializes remotes and automatic loading. Called by the bootstrap. |
| `DogeService:GetProfile(player)` | Returns the active profile, or `nil` if it is not ready. |
| `DogeService:WaitForProfile(player, timeoutSeconds)` | Waits for the active profile. |
| `DogeService:GetValue(player, path, defaultValue)` | Reads a value from a profile. |
| `DogeService:SetValue(player, path, value)` | Validates and sets a value. |
| `DogeService:Increment(player, path, amount)` | Adds a number to a numeric value. |
| `DogeService:GetInventory(player)` | Returns a copy of the inventory table. |
| `DogeService:AddItem(player, itemId, quantity)` | Adds to an inventory stack. |
| `DogeService:RemoveItem(player, itemId, quantity)` | Removes from an inventory stack. |

### Server profile object

| Property / method | Purpose |
| --- | --- |
| `profile.Name`, `profile.UserId` | Profile owner's current name and user ID. |
| `profile.Data` | The server's underlying data table. Treat it as server-only. |
| `profile:IsActive()` | Whether the profile session is active. |
| `profile:GetName()`, `profile:GetUserId()` | Get owner information. |
| `profile:Get(path, defaultValue)` | Read a value. Returns a copy of the selected value. |
| `profile:GetValue(path, defaultValue)` | Alias for `Get`. |
| `profile:Set(path, value)` | Set a value; returns success and result/error. |
| `profile:Increment(path, amount)` | Increment a numeric value. |
| `profile:GetInventory()` | Get a copy of the inventory. |
| `profile:AddItem(itemId, quantity)` | Add an item; defaults to quantity `1`. |
| `profile:RemoveItem(itemId, quantity)` | Remove an item; defaults to quantity `1`. |
| `profile:HasItem(itemId, quantity)` | Check item quantity. |
| `profile:Sync()` | Push a direct server-side `profile.Data` edit to the client snapshot. |
| `profile:Save()` | Request an immediate save. |
| `profile:Release()` | Save and release the session. Normally handled automatically. |

### Client module

On the client, require the same `ReplicatedStorage.DogeService` ModuleScript. It exposes read-only methods:

- `DogeService:WaitForProfile(timeoutSeconds)`
- `DogeService:GetProfile(forceRefresh)`
- `DogeService:GetValue(path, defaultValue, forceRefresh)`
- `DogeService:GetInventory(forceRefresh)`
- `DogeService:GetName(forceRefresh)`
- `DogeService:GetUserId(forceRefresh)`
- `DogeService:IsLoaded()`
- `DogeService.ProfileUpdated` event

Client-side `SetValue`, `Increment`, `AddItem`, and `RemoveItem` intentionally return `false`. For a gameplay action, ask the server through a game-specific remote and validate the request on the server.

### Paths and return values

Use dot-separated paths for ordinary table keys:

```lua
profile:Get("Currency.Coins", 0)
profile:Set("Settings.Music", false)
profile:Increment("Stats.XP", 50)
```

Use a path table for numeric array indexes:

```lua
profile:Get({ "SomeArray", 1 })
```

Mutation methods return a success boolean followed by the new value or an error message. Always check the boolean before assuming a mutation succeeded.

## 🔐 Security model

**The server is the source of truth.** Never trust the client to set currency, inventory, progression, trading results, rewards, or arbitrary profile paths.

For client-initiated gameplay actions:

1. Create a dedicated `RemoteEvent` or `RemoteFunction` for the specific action.
2. Validate the requested action and all arguments on the server.
3. Check current profile values, item ownership, price, cooldown, distance, and any other game-specific requirements.
4. Change profile data only after the checks pass.

Do not expose a remote that lets a client choose an arbitrary player, path, or new value. DogeService's profile snapshots are for client display—not permission to edit saved data.

## ⚠️ Limitations and testing

- This is a starter data module and has not been verified across every Roblox server lifecycle or failure scenario.
- Autosaving and session leases reduce risk; they cannot eliminate DataStore outages, all race conditions, or every possible data-loss scenario.
- Test join/leave, reconnects, rapid server hops, DataStore throttling, shutdown saves, schema changes, and invalid data before production use.
- Keep important purchases and trades idempotent and design explicit recovery behavior for failed saves.
- Do not use player profiles as a global leaderboard or as a rapidly shared global counter; use an appropriate Roblox service/pattern for that workload.
- Make a separate test experience and test data store before experimenting with live saved data.

## 🌐 Publish the project page with GitHub Pages

This repository includes a static site at `docs/index.html`.

1. Push these files to a GitHub repository.
2. Open the repository's **Settings → Pages**.
3. Under **Build and deployment**, choose **Deploy from a branch**.
4. Select your default branch and the `/docs` folder, then save.
5. Wait for GitHub Pages to publish the site. GitHub will show the resulting URL in the Pages settings.

The site is static HTML/CSS and needs no build step. The README remains the main project documentation on the repository's front page.

## 📚 References

- [Roblox Data stores](https://create.roblox.com/docs/cloud-services/data-stores)
- [Roblox client-server security](https://create.roblox.com/docs/scripting/security/client-server-boundary)
- [GitHub Pages documentation](https://docs.github.com/en/pages)

---

<div align="center">

Made for Roblox developers · Built with Luau

</div>
