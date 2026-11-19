# Plugin Development & Reloading Notes

## Reloading Rebuilt Plugins in Roblox Studio
Rebuilding a plugin (for example via `build.ps1` to `%LOCALAPPDATA%\Roblox\Plugins\`) does **not** automatically reload the active plugin inside an open Roblox Studio session.

After making modifications and rebuilding a plugin:
1. **Mount the rebuilt plugin inside `Workspace`** in Roblox Studio.
2. **Ask the user to save it as a local plugin** (right-click the mounted plugin in Explorer -> **Save as Local Plugin...**) so Roblox Studio reloads the updated plugin immediately.
