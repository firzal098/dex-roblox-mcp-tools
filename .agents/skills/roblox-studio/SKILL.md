---
name: roblox-studio
description: >
  Interact with a live Roblox Studio session via MCP tools. Inspect the game tree,
  read instance properties using ReflectionService, search by class/name, and find
  instances by CollectionService tags. Requires the MCP server and Studio plugin running.
---

# Roblox Studio MCP Tools

You have access to a set of MCP tools that communicate with a **live Roblox Studio session** in real-time via WebSocket. Use these to understand the game hierarchy, inspect properties, and find specific instances.

## Prerequisites

Before using these tools, ensure:
1. The Python MCP server is running (it starts automatically when Antigravity loads)
2. Roblox Studio is open with the **MCP Bridge plugin** active (auto-activates on Studio start)
3. The plugin shows "✅ Connected" in the Studio output

## Available Tools

### `roblox_ls` — List Children
List direct children of any instance in the game tree.

**Path syntax:** Dot-separated from `game` root.
```
game                              → Top-level services
game.Workspace                    → All objects in Workspace
game.ReplicatedStorage            → Shared storage
game.ServerStorage                → Server-only storage
game.StarterPlayer.StarterPlayerScripts → Starter scripts
game.Lighting                     → Lighting objects
game.Workspace.MyModel            → A specific model
```

**Example use cases:**
- Explore the top-level structure: `roblox_ls("game")`
- See what's in Workspace: `roblox_ls("game.Workspace")`
- Inspect a model's children: `roblox_ls("game.Workspace.MyModel")`

### `roblox_ls_descendants` — Recursive Tree
Get the full descendant tree of an instance, useful for understanding complex hierarchies.

**Parameters:**
- `path`: Instance path
- `max_depth`: How deep to go (1-20, default 5)

**Example use cases:**
- Full Workspace overview: `roblox_ls_descendants("game.Workspace", max_depth=3)`
- Inspect a UI tree: `roblox_ls_descendants("game.StarterGui", max_depth=4)`

### `roblox_ls_summary` — Children with Properties
Like `ls` but includes **key properties** for each child based on its ClassName. Much more informative — shows Position, Size, Value, Text, etc.

**Example use cases:**
- See parts with positions/sizes: `roblox_ls_summary("game.Workspace")`
- Inspect UI elements with their text/colors: `roblox_ls_summary("game.StarterGui.ScreenGui.Frame")`
- Check value objects: `roblox_ls_summary("game.ReplicatedStorage.Config")`

### `roblox_get_properties` — Full Property Dump
Get **every property** of an instance via ReflectionService. Returns property names, values, types, and serialization info.

**Example use cases:**
- Inspect a Part fully: `roblox_get_properties("game.Workspace.SpawnLocation")`
- Check a script's settings: `roblox_get_properties("game.ServerScriptService.MainScript")`
- Examine a UI element: `roblox_get_properties("game.StarterGui.ScreenGui.Frame.Title")`

### `roblox_get_by_tag` — Find by CollectionService Tag
Find all instances that have a specific CollectionService tag.

**Example use cases:**
- Find all enemies: `roblox_get_by_tag("Enemy")`
- Find interactable objects: `roblox_get_by_tag("Interactable")`
- Find waypoints: `roblox_get_by_tag("Waypoint")`

### `roblox_search` — Search by Class/Name
Search descendants for instances matching a ClassName and/or name pattern.

**Parameters:**
- `path`: Where to search from
- `class_name`: Filter by ClassName (supports IsA, e.g. "BasePart" matches Part, MeshPart, etc.)
- `name_pattern`: Filter by name substring (case-insensitive)
- `max_depth`: Search depth (1-50, default 10)

**Example use cases:**
- Find all Scripts in game: `roblox_search("game", class_name="Script")`
- Find parts named "Door": `roblox_search("game.Workspace", class_name="BasePart", name_pattern="door")`
- Find all ModuleScripts: `roblox_search("game", class_name="ModuleScript")`

### `roblox_verify_script` — Verify Script Existence
Check if a script or instance exists at a given path. Optionally creates it if missing when `create_if_missing=True`.

**Example use cases:**
- Verify if a script exists: `roblox_verify_script("game.ReplicatedStorage.MyModule")`
- Verify and create if missing: `roblox_verify_script("game.ReplicatedStorage.MyModule", create_if_missing=True, script_type="ModuleScript", source="...")`

### `roblox_create_script` — Safe Script Creation
Create a `Script`, `LocalScript`, or `ModuleScript` under `parent_path` with a `source` payload. **Only creates the script if no script with that name currently exists.**

**Example use cases:**
- Create a server script: `roblox_create_script("game.ServerScriptService", name="GameManager", script_type="Script", source="print('Hello Server')")`
- Create a module script: `roblox_create_script("game.ReplicatedStorage", name="Config", script_type="ModuleScript", source="return { Version = 1 }")`

### `roblox_take_viewport_screenshot` — VLA Viewport Screenshot
Capture a visual screenshot of the Roblox Studio window/viewport for VLA (Vision-Language-Action) visual testing.

**Prerequisite:** Requires the Vision Bridge helper running in your interactive terminal: `python vision_bridge.py`.

**Example use case:**
- Capture current viewport image for VLA visual verification: `roblox_take_viewport_screenshot()`

## Common Workflows

### Exploring an unfamiliar game
1. Start with `roblox_ls("game")` to see top-level services
2. `roblox_ls("game.Workspace")` to see the world
3. `roblox_ls_summary("game.Workspace")` for more detail
4. Drill into interesting items with `roblox_get_properties("game.Workspace.ItemName")`

### Finding and inspecting scripts
1. `roblox_search("game", class_name="Script")` to find all scripts
2. `roblox_get_properties("game.ServerScriptService.MyScript")` for script settings

### Understanding a UI hierarchy
1. `roblox_ls_descendants("game.StarterGui", max_depth=4)` for the full UI tree
2. `roblox_ls_summary("game.StarterGui.ScreenGui.MainFrame")` for element properties
3. `roblox_get_properties(...)` for any specific element

### Working with tagged systems
1. `roblox_get_by_tag("MyTag")` to find all tagged instances
2. `roblox_get_properties(...)` on individual results for full details

## Tips
- Paths are **case-sensitive** and must match exact instance names
- Use `roblox_ls` first to discover correct child names before drilling deeper
- `roblox_ls_summary` is the best starting tool — it gives you the most information per call
- The `search` tool with `class_name="BasePart"` finds Part, MeshPart, WedgePart, etc. (uses IsA)
- If you get "No Roblox Studio connected", ask the user to open Studio and check the plugin
