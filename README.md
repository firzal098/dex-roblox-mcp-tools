# Roblox MCP Tools

A FastMCP server and Roblox Studio plugin bridge that lets AI agents inspect, edit, preview UI stories, capture viewport screenshots, and playtest directly inside Roblox Studio in real time.

## Architecture

```text
MCP Client / Agent ──(MCP stdio)──▶ server.py ──(WebSocket :8000)──▶ Roblox Studio Plugin (MCPBridge)
                                        │                                      │
                                        │                                      └─▶ StudioCaptureService (Primary)
                                        └──(On-demand fallback :8001)──▶ vision_bridge.py (Windows capture)
```

- **`server.py`** — FastMCP server exposing Roblox Studio tools over `stdio` and hosting the WebSocket bridge on `ws://127.0.0.1:8000`.
- **`opencloud_assets.py`** — Roblox Open Cloud Assets API & Asset Delivery helper (multi-group/user creator matching, upload polling, Decal -> Image unwrapping, and Windows Credential Manager integration).
- **`setup_credentials.py`** — Interactive terminal helper to store Open Cloud API keys encrypted in Windows Credential Manager (`keyring`) instead of `.env`.
- **`plugin/`** — Rojo project for the `MCPBridge` Roblox Studio plugin (`src/init.server.luau`), including native `StudioCaptureService` viewport capture and place creator inspection.
- **`vision_bridge.py`** — Optional Windows desktop HTTP fallback (`http://127.0.0.1:8001`) invoked only on demand if `StudioCaptureService` is unavailable or denied.

## Repository Layout

```text
roblox-mcp-tools/
├── server.py               # FastMCP server + WebSocket bridge (:8000)
├── opencloud_assets.py     # Open Cloud upload/read + multi-group auto-routing
├── setup_credentials.py    # Interactive keyring credential setup
├── .env.example            # Template for non-secret user/group IDs & config
├── vision_bridge.py        # Optional Windows viewport screenshot fallback (:8001)
├── take_screenshot.py      # Standalone manual screenshot test script
├── run_vision_bridge.bat   # Launcher for vision_bridge.py fallback server
├── take_screenshot.bat     # Launcher for take_screenshot.py
├── requirements.txt        # Python dependencies
└── plugin/                 # Rojo source project for the Studio plugin
    ├── default.project.json
    ├── rokit.toml
    ├── build.ps1           # Builds mcp.rbxmx to %LOCALAPPDATA%\Roblox\Plugins\
    ├── AGENTS.md
    └── src/
        └── init.server.luau
```

## Prerequisites

- **Python 3.10+**
- **Roblox Studio** (with HTTP Requests enabled; grant the one-time Studio screenshot permission prompt for `StudioCaptureService`)
- **Rokit** (or **Rojo 7.7.1+**) to build the Studio plugin
- **Pillow** (`pip install pillow`) — optional, only required for the Windows `vision_bridge.py` fallback or `RGBA8` captures

## Setup

### 1. Install Python Dependencies

```bash
pip install -r requirements.txt
# Optional (only needed for Windows vision_bridge.py fallback):
pip install pillow
```

### 2. Build the Roblox Studio Plugin

From the `plugin/` directory:

```powershell
cd plugin
.\build.ps1
```

This builds `mcp.rbxmx` into `%LOCALAPPDATA%\Roblox\Plugins\mcp.rbxmx`. Restart Roblox Studio (or save as a local plugin in Studio) and click **MCP Bridge** in the Plugins toolbar to connect.

### 3. Configure Your MCP Client

Add `server.py` as an MCP `stdio` server in your client configuration:

```json
{
  "mcpServers": {
    "roblox-studio": {
      "command": "python",
      "args": ["C:/path/to/roblox-mcp-tools/server.py"]
    }
  }
}
```

### 4. Open Cloud Image Upload & Asset Reader (Optional)

1. Copy `.env.example` to `.env` and set your public creator IDs:
   ```dotenv
   ROBLOX_USER_ID=12345678
   ROBLOX_GROUP_IDS=dexite:7154107,secondary:33445566
   ```
2. Create an Open Cloud API Key at [create.roblox.com/credentials](https://create.roblox.com/credentials) with `asset:read`, `asset:write`, and `legacy-asset:manage`.
3. Store the key securely in Windows Credential Manager (never plaintext in `.env`):
   ```powershell
   python setup_credentials.py
   ```
4. With `creator_type="auto"` (default), `roblox_upload_image_asset` reads the open Studio place's `CreatorType`/`CreatorId` and automatically picks the matching User or Group ID from `.env`.

### 5. Vision Bridge Fallback (Optional, Windows)

Screenshots use `StudioCaptureService` over WebSocket by default and do not require `vision_bridge.py`. If you want the Windows fallback server available in your interactive desktop session when Studio is unfocused or screenshot permissions are disabled, run:

```powershell
.\run_vision_bridge.bat
```

## Available MCP Tools

- **Explorer & Inspection:** `roblox_ls`, `roblox_ls_descendants`, `roblox_ls_summary`, `roblox_get_properties`, `roblox_get_by_tag`, `roblox_search`, `roblox_get_attributes`, `roblox_get_place_info`
- **Open Cloud Assets:** `roblox_upload_image_asset`, `roblox_get_image_asset`
- **Scripts & Editing:** `roblox_verify_script`, `roblox_create_script`, `roblox_execute_code`, `roblox_set_properties`, `roblox_set_attribute`, `roblox_get_output_logs`
- **UI & Story Preview:** `roblox_get_ui_tree`, `roblox_get_ui_design_properties`, `roblox_inspect_ui_component`, `roblox_get_ui_palette`, `roblox_mount_story`, `roblox_unmount_story`, `roblox_list_mounted_stories`, `roblox_unmount_all_stories`
- **Viewport & Camera:** `roblox_get_viewport_size`, `roblox_take_viewport_screenshot`, `roblox_get_selection`, `roblox_set_selection`, `focus_on_selection`, `roblox_focus_on_selection`, `roblox_world_to_screen`, `roblox_look_at`, `roblox_set_camera`
- **Playtest & Input Automation:** `roblox_start_playtest`, `roblox_stop_playtest`, `roblox_get_playtest_mode`, `roblox_get_player_state`, `roblox_teleport`, `roblox_equip_tool`, `roblox_chat`, `roblox_get_active_proximity_prompts`, `roblox_trigger_prompt`, `roblox_simulate_input`, `roblox_input_sequence`, `roblox_click_ui_element`, `roblox_wait_for`

## Security Note

The Studio plugin connects only to `ws://127.0.0.1:8000` and exposes `roblox_execute_code` for local development. Only run the bridge in trusted local Studio sessions.

## License

[MIT](LICENSE)
