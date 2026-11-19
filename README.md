# Roblox MCP Tools

A FastMCP server and Roblox Studio plugin bridge that lets AI agents inspect, edit, preview UI stories, capture viewport screenshots, and playtest directly inside Roblox Studio in real time.

## Architecture

```text
MCP Client / Agent ──(MCP stdio)──▶ server.py ──(WebSocket :8000)──▶ Roblox Studio Plugin (MCPBridge)
                                        │
                                        └──(HTTP :8001)──▶ vision_bridge.py (Windows viewport capture)
```

- **`server.py`** — FastMCP server exposing Roblox Studio tools over `stdio` and hosting the WebSocket bridge on `ws://127.0.0.1:8000`.
- **`plugin/`** — Rojo project for the `MCPBridge` Roblox Studio plugin (`src/init.server.luau`).
- **`vision_bridge.py`** — Windows desktop HTTP server on `http://127.0.0.1:8001` for capturing the Roblox Studio 3D viewport (`take_screenshot.py` / `run_vision_bridge.bat`).

## Repository Layout

```text
roblox-mcp-tools/
├── server.py               # FastMCP server + WebSocket bridge (:8000)
├── vision_bridge.py        # Windows viewport screenshot HTTP bridge (:8001)
├── take_screenshot.py      # Standalone manual screenshot test script
├── run_vision_bridge.bat   # Launcher for vision_bridge.py
├── take_screenshot.bat     # Launcher for take_screenshot.py
├── requirements.txt        # Core Python dependencies
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
- **Roblox Studio** (with HTTP Requests / WebSocket client enabled when running plugins)
- **Rokit** (or **Rojo 7.7.1+**) to build the Studio plugin
- **Pillow** (`pip install pillow`) if using `vision_bridge.py` / `roblox_take_viewport_screenshot` on Windows

## Setup

### 1. Install Python Dependencies

```bash
pip install -r requirements.txt
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

### 4. Vision Bridge (Optional, Windows)

`server.py` automatically starts the Vision Bridge on port `8001` when needed, or you can run it explicitly in your interactive desktop session:

```powershell
.\run_vision_bridge.bat
```

## Available MCP Tools

- **Explorer & Inspection:** `roblox_ls`, `roblox_ls_descendants`, `roblox_ls_summary`, `roblox_get_properties`, `roblox_get_by_tag`, `roblox_search`, `roblox_get_attributes`
- **Scripts & Editing:** `roblox_verify_script`, `roblox_create_script`, `roblox_execute_code`, `roblox_set_properties`, `roblox_set_attribute`, `roblox_get_output_logs`
- **UI & Story Preview:** `roblox_get_ui_tree`, `roblox_get_ui_design_properties`, `roblox_inspect_ui_component`, `roblox_get_ui_palette`, `roblox_mount_story`, `roblox_unmount_story`, `roblox_list_mounted_stories`, `roblox_unmount_all_stories`
- **Viewport & Camera:** `roblox_get_viewport_size`, `roblox_take_viewport_screenshot`, `roblox_get_selection`, `roblox_set_selection`, `focus_on_selection`, `roblox_focus_on_selection`, `roblox_world_to_screen`, `roblox_look_at`, `roblox_set_camera`
- **Playtest & Input Automation:** `roblox_start_playtest`, `roblox_stop_playtest`, `roblox_get_playtest_mode`, `roblox_get_player_state`, `roblox_teleport`, `roblox_equip_tool`, `roblox_chat`, `roblox_get_active_proximity_prompts`, `roblox_trigger_prompt`, `roblox_simulate_input`, `roblox_input_sequence`, `roblox_click_ui_element`, `roblox_wait_for`

## Security Note

The Studio plugin connects only to `ws://127.0.0.1:8000` and exposes `roblox_execute_code` for local development. Only run the bridge in trusted local Studio sessions.

## License

[MIT](LICENSE)
