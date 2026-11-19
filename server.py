"""
Roblox MCP Tools — FastMCP Server with WebSocket Bridge

Architecture:
  Antigravity ←(MCP stdio)→ This Server ←(WebSocket)→ Roblox Studio Plugin

The server exposes MCP tools (roblox_ls, roblox_get_properties, etc.) and runs
a WebSocket server on port 8000. The Roblox Studio plugin connects via WebSocket
for instant bidirectional communication — no polling needed.
"""

import asyncio
import json
import uuid
import logging
import os
import sys
import subprocess
import time
from typing import Optional, Any

from fastmcp import FastMCP

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("roblox-mcp")

# ---------------------------------------------------------------------------
# FastMCP Server
# ---------------------------------------------------------------------------
mcp = FastMCP(
    "roblox-studio",
    instructions=(
        "MCP server for inspecting, interacting with, and autonomous playtesting in Roblox Studio in real-time. "
        "Use roblox_ls to list children, roblox_ls_descendants for recursive tree, "
        "roblox_ls_summary for children with key properties, roblox_get_properties "
        "for full property inspection via ReflectionService, roblox_get_by_tag "
        "to find instances by CollectionService tag, roblox_verify_script to check script existence, "
        "roblox_create_script to safely create scripts with source payloads, "
        "roblox_execute_code for dual-stage Luau execution in Edit or Playtest Mode, "
        "roblox_get_output_logs for Studio output window logs, "
        "roblox_set_properties to modify instance properties, "
        "roblox_set_attribute and roblox_get_attributes for instance attributes, "
        "roblox_get_selection and roblox_set_selection for Studio Selection, "
        "focus_on_selection to zoom the Studio camera to an instance, "
        "roblox_get_ui_tree for clean UI hierarchies, roblox_get_ui_design_properties for UI styling/layout, "
        "roblox_inspect_ui_component for component + modifier inspection, "
        "roblox_get_ui_palette for aggregated UI design tokens, "
        "roblox_mount_story to preview UI stories in Edit mode without UI Labs, "
        "roblox_unmount_story, roblox_list_mounted_stories, roblox_unmount_all_stories, "
        "roblox_get_active_proximity_prompts to discover nearby prompts, "
        "roblox_trigger_prompt to activate/hold prompts, "
        "roblox_simulate_input for keyboard/mouse simulation, "
        "roblox_input_sequence for batched actions with timings, "
        "roblox_click_ui_element to auto-click buttons in PlayerGui, "
        "roblox_world_to_screen to project 3D parts to 2D pixels, "
        "roblox_look_at and roblox_set_camera for camera control, "
        "roblox_teleport to move characters, "
        "roblox_equip_tool to equip backpack items, "
        "roblox_get_player_state for player attributes and status, "
        "roblox_chat for in-game chat, "
        "roblox_wait_for to poll conditions, "
        "and roblox_start_playtest / roblox_stop_playtest for session control."
    ),
)

# ---------------------------------------------------------------------------
# Command Queue — shared state between MCP tools and WebSocket
# ---------------------------------------------------------------------------
# pending_commands: {command_id: {"command": ..., "params": ..., "event": asyncio.Event, "result": ...}}
pending_commands: dict[str, dict] = {}

# Connected Roblox Studio WebSocket clients
studio_connections: set = set()
connection_contexts: dict = {}  # websocket -> "edit" | "server" | "client" | "unknown"

# Lock for thread safety
connections_lock = asyncio.Lock()

COMMAND_TIMEOUT = 30  # seconds

CLIENT_ONLY_COMMANDS = {
    "simulate_input",
    "input_sequence",
    "click_ui_element",
    "world_to_screen",
    "look_at",
    "set_camera",
    "get_viewport_size",
    "get_active_proximity_prompts",
    "get_ui_tree",
    "get_ui_design_properties",
    "inspect_ui_component",
    "get_ui_palette",
}

EDIT_ONLY_COMMANDS = set()


async def send_command_to_studio(command: str, params: dict, target_context: Optional[str] = None) -> dict:
    """
    Send a command to Roblox Studio via WebSocket and wait for the response.
    Supports intelligent context routing ('server' vs 'client' vs 'edit') to avoid multi-connection race conditions.
    Returns the result dict or raises an error.
    """
    if not studio_connections:
        return {"error": "No Roblox Studio instance connected. Please ensure the RobloxMCPBridge plugin is installed and Studio is open."}

    # Resolve target context if not explicitly provided
    resolved_target = target_context or params.get("target_context") or params.get("context")
    if not resolved_target or resolved_target in ("auto", "any"):
        if command in CLIENT_ONLY_COMMANDS:
            resolved_target = "client"
        elif command in EDIT_ONLY_COMMANDS:
            resolved_target = "edit"
        elif command == "execute_code":
            # If server connection is available during playtest, default to server; else edit/client
            has_server = any(connection_contexts.get(ws) == "server" for ws in studio_connections)
            if has_server:
                resolved_target = "server"
            else:
                resolved_target = None
        else:
            resolved_target = None

    command_id = str(uuid.uuid4())
    event = asyncio.Event()

    pending_commands[command_id] = {
        "command": command,
        "params": params,
        "event": event,
        "result": None,
        "target_context": resolved_target,
    }

    message_payload = {
        "id": command_id,
        "command": command,
        "params": params,
    }
    if resolved_target:
        message_payload["target_context"] = resolved_target

    message = json.dumps(message_payload)

    async with connections_lock:
        dead = set()
        candidate_sockets = []
        for ws in studio_connections:
            ctx = connection_contexts.get(ws, "unknown")
            if not resolved_target or resolved_target == "any" or ctx == resolved_target or ctx == "unknown":
                candidate_sockets.append(ws)

        # Fallback if no matching socket found
        if not candidate_sockets:
            candidate_sockets = list(studio_connections)

        for ws in candidate_sockets:
            try:
                await ws.send(message)
            except Exception:
                dead.add(ws)
        studio_connections.difference_update(dead)
        for d in dead:
            connection_contexts.pop(d, None)

    if not studio_connections and not pending_commands[command_id]["result"]:
        del pending_commands[command_id]
        return {"error": "Lost connection to Roblox Studio while sending command."}

    # Wait for response
    try:
        await asyncio.wait_for(event.wait(), timeout=COMMAND_TIMEOUT)
    except asyncio.TimeoutError:
        del pending_commands[command_id]
        ctx_info = f" (target_context: {resolved_target})" if resolved_target else ""
        return {"error": f"Command '{command}' timed out after {COMMAND_TIMEOUT}s{ctx_info}. Studio may be unresponsive."}

    result = pending_commands.pop(command_id)["result"]
    return result


def format_result(result: dict) -> str:
    """Format a result dict into a readable string for the LLM."""
    if "error" in result:
        return f"❌ Error: {result['error']}"
    return json.dumps(result.get("data", result), indent=2, ensure_ascii=False)


# ---------------------------------------------------------------------------
# MCP Tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def roblox_ls(path: str) -> str:
    """
    List the direct children of a Roblox instance.

    Args:
        path: Dot-separated path to the instance (e.g. "game.Workspace",
              "game.ReplicatedStorage.Modules", "game.Workspace.MyModel").
              Use "game" to list top-level services.

    Returns:
        A list of children with their Name and ClassName.
    """
    result = await send_command_to_studio("ls", {"path": path})
    return format_result(result)


@mcp.tool()
async def roblox_ls_descendants(path: str, max_depth: int = 5) -> str:
    """
    List all descendants of a Roblox instance recursively as an indented tree.

    Args:
        path: Dot-separated path to the instance (e.g. "game.Workspace").
        max_depth: Maximum depth to traverse (default 5, max 20).

    Returns:
        An indented tree of descendants with Name and ClassName.
    """
    max_depth = min(max(1, max_depth), 20)
    result = await send_command_to_studio("ls_descendants", {"path": path, "max_depth": max_depth})
    return format_result(result)


@mcp.tool()
async def roblox_ls_summary(path: str) -> str:
    """
    List children of a Roblox instance with summary properties.
    Shows each child's key properties (Position, Size, Value, Text, etc.)
    based on their ClassName — much more informative than a plain ls.

    Args:
        path: Dot-separated path (e.g. "game.Workspace").

    Returns:
        Children with their ClassName and key property values.
    """
    result = await send_command_to_studio("ls_summary", {"path": path})
    return format_result(result)


@mcp.tool()
async def roblox_get_properties(path: str) -> str:
    """
    Get all readable properties of a Roblox instance using ReflectionService.
    This returns every property the instance has, including inherited ones.

    Args:
        path: Dot-separated path (e.g. "game.Workspace.SpawnLocation").

    Returns:
        A dictionary of all properties with their current values and types.
    """
    result = await send_command_to_studio("get_properties", {"path": path})
    return format_result(result)


@mcp.tool()
async def roblox_get_by_tag(tag: str) -> str:
    """
    Find all instances in the game that have a specific CollectionService tag.

    Args:
        tag: The tag name to search for.

    Returns:
        A list of instances with the tag, showing their full path and ClassName.
    """
    result = await send_command_to_studio("get_by_tag", {"tag": tag})
    return format_result(result)


@mcp.tool()
async def roblox_search(path: str, class_name: Optional[str] = None, name_pattern: Optional[str] = None, max_depth: int = 10) -> str:
    """
    Search for instances under a path by ClassName and/or name pattern.

    Args:
        path: Dot-separated path to search under (e.g. "game.Workspace").
        class_name: Filter by ClassName (e.g. "Part", "Script", "ModuleScript"). Optional.
        name_pattern: Filter by name substring (case-insensitive). Optional.
        max_depth: Maximum depth to search (default 10).

    Returns:
        Matching instances with their full path and ClassName.
    """
    params = {"path": path, "max_depth": min(max(1, max_depth), 50)}
    if class_name:
        params["class_name"] = class_name
    if name_pattern:
        params["name_pattern"] = name_pattern
    result = await send_command_to_studio("search", params)
    return format_result(result)


@mcp.tool()
async def roblox_get_viewport_size() -> str:
    """
    Get the exact 3D viewport canvas width and height (Vector2) from Roblox Studio's active Camera.

    Returns:
        JSON response with the 3D viewport width and height in pixels.
    """
    result = await send_command_to_studio("get_viewport_size", {})
    return format_result(result)


@mcp.tool()
async def roblox_take_viewport_screenshot(crop_viewport: bool = True) -> str:
    """
    Take a visual screenshot of the Roblox Studio viewport/window for VLA (Vision-Language-Action) testing.
    Automatically starts the Vision Bridge server in the background if not already running.

    Args:
        crop_viewport: If True (default), automatically crops strictly to the 3D Viewport canvas.
                       If False, captures the full Studio window.

    Returns:
        JSON response with the captured screenshot file path, dimensions, and window title.
    """
    import urllib.request
    import json

    # Auto-start Vision Bridge if not responding
    if not is_vision_bridge_running(8001):
        start_vision_bridge_server(8001)

    url = f"http://127.0.0.1:8001/capture?crop={'true' if crop_viewport else 'false'}"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FastMCP"})
        with urllib.request.urlopen(req, timeout=8) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            return json.dumps(data, indent=2)
    except Exception as http_err:
        # Fallback to direct in-process capture if HTTP endpoint failed
        try:
            import vision_bridge
            result = vision_bridge.capture_studio_viewport(crop_viewport=crop_viewport)
            return json.dumps(result, indent=2)
        except Exception as direct_err:
            return json.dumps({
                "error": "Failed to capture Roblox Studio screenshot.",
                "http_error": str(http_err),
                "direct_error": str(direct_err),
            }, indent=2)


@mcp.tool()
async def roblox_verify_script(
    path: str,
    create_if_missing: bool = False,
    script_type: str = "Script",
    source: str = ""
) -> str:
    """
    Verify whether a script or instance exists at the specified dot-separated path.
    Optionally create it (as Script, LocalScript, or ModuleScript) with a source payload if it does not exist.

    Args:
        path: Dot-separated path to the script (e.g. "game.ReplicatedStorage.MyModule").
        create_if_missing: If True and the script does not exist, create it automatically.
        script_type: Type of script to create if missing ("Script", "LocalScript", or "ModuleScript"). Default "Script".
        source: Source code payload to write to the script if created.

    Returns:
        JSON response with script verification status and creation info if created.
    """
    params = {
        "path": path,
        "create_if_missing": create_if_missing,
        "script_type": script_type,
        "source": source,
    }
    result = await send_command_to_studio("verify_script", params)
    return format_result(result)


@mcp.tool()
async def roblox_create_script(
    parent_path: str,
    name: str,
    script_type: str = "Script",
    source: str = ""
) -> str:
    """
    Create a new Script, LocalScript, or ModuleScript under parent_path with the given name and source code.
    Only creates the script if no instance with that name already exists under parent_path.

    Args:
        parent_path: Dot-separated path to the parent instance (e.g. "game.ServerScriptService").
        name: Name of the script to create (e.g. "GameManager").
        script_type: Type of script to create ("Script", "LocalScript", or "ModuleScript"). Default "Script".
        source: Source code payload to write into the script.

    Returns:
        JSON response indicating whether the script was created or already existed.
    """
    params = {
        "parent_path": parent_path,
        "name": name,
        "script_type": script_type,
        "source": source,
    }
    result = await send_command_to_studio("create_script", params)
    return format_result(result)


@mcp.tool()
async def roblox_get_ui_tree(path: str, max_depth: int = 4, include_layout_components: bool = True) -> str:
    """
    Retrieves a simplified hierarchy tree of UI instances starting from a target path.
    Automatically filters out non-UI instances and returns clean class names.

    Args:
        path: The instance path to start from (e.g., 'StarterGui.ShopMenu').
        max_depth: Maximum tree depth to query (default 4).
        include_layout_components: Whether to include UIListLayout, UICorner, UIPadding, etc. (default True).

    Returns:
        JSON response with the filtered UI hierarchy tree.
    """
    params = {
        "path": path,
        "max_depth": min(max(1, max_depth), 20),
        "include_layout_components": include_layout_components,
    }
    result = await send_command_to_studio("get_ui_tree", params)
    return format_result(result)


@mcp.tool()
async def roblox_get_ui_design_properties(path: str, include_defaults: bool = False) -> str:
    """
    Returns key design properties (styling, layout, typography) for a given UI instance,
    omitting default visual properties and engine metadata.

    Args:
        path: The exact path to the UI instance (e.g., 'StarterGui.ShopMenu.MainFrame.HeaderLabel').
        include_defaults: If False, omits transparent backgrounds, zero borders, and standard engine defaults to keep output minimal.

    Returns:
        JSON response with clean layout, styling, and typography properties.
    """
    params = {
        "path": path,
        "include_defaults": include_defaults,
    }
    result = await send_command_to_studio("get_ui_design_properties", params)
    return format_result(result)


@mcp.tool()
async def roblox_inspect_ui_component(path: str) -> str:
    """
    Fetches a UI element's visual properties along with any child UI modifiers
    (UICorner, UIPadding, UIListLayout, etc.) affecting its presentation.

    Args:
        path: Path to the component to inspect (e.g., 'StarterGui.ShopMenu.MainFrame').

    Returns:
        JSON response with component design properties and child layout modifiers.
    """
    params = {"path": path}
    result = await send_command_to_studio("inspect_ui_component", params)
    return format_result(result)


@mcp.tool()
async def roblox_get_ui_palette(path: str, include_counts: bool = True) -> str:
    """
    Scans a UI subtree and extracts an aggregated design palette containing unique
    color swatches, typography styles, asset image IDs, and layout metrics used across all descendant components.

    Args:
        path: Path to the UI root instance (e.g., 'StarterGui.ShopMenu').
        include_counts: If True, includes frequency counts showing how often each color, font, or image asset is reused across the UI.

    Returns:
        JSON response with aggregated design tokens (colors, typography, images, layout metrics).
    """
    params = {
        "path": path,
        "include_counts": include_counts,
    }
    result = await send_command_to_studio("get_ui_palette", params)
    return format_result(result)


@mcp.tool()
async def roblox_mount_story(path: str, controls: Optional[dict] = None) -> str:
    """
    Mount a UI story (e.g. *.story.luau) directly into StarterGui in Edit mode for instant visual previewing.
    Autonomous: renders in Edit mode without needing UI Labs or Studio playtest.
    Captures and returns Roblox Studio output logs (error, warning, normal) emitted during mounting.

    Args:
        path: Dot-separated path to the story ModuleScript (e.g. 'StarterPlayer.StarterPlayerScripts.UI.Intro.IntroScreen.story').
        controls: Optional dictionary of control override values to supply to the story props.

    Returns:
        JSON response with mount status, target ScreenGui path, applied controls, and captured studio output logs (error/warning/normal).
    """
    params = {"path": path}
    if controls:
        params["controls"] = controls
    result = await send_command_to_studio("mount_story", params)
    return format_result(result)


@mcp.tool()
async def roblox_unmount_story(path: str) -> str:
    """
    Unmount a previously mounted UI story and cleanly destroy its preview ScreenGui.

    Args:
        path: Dot-separated path to the story ModuleScript (e.g. 'StarterPlayer.StarterPlayerScripts.UI.Intro.IntroScreen.story').

    Returns:
        JSON response with unmount confirmation.
    """
    params = {"path": path}
    result = await send_command_to_studio("unmount_story", params)
    return format_result(result)


@mcp.tool()
async def roblox_list_mounted_stories() -> str:
    """
    List all currently mounted UI stories and their active preview containers in StarterGui.

    Returns:
        JSON response with the list of mounted stories, paths, and creation timestamps.
    """
    result = await send_command_to_studio("list_mounted_stories", {})
    return format_result(result)


@mcp.tool()
async def roblox_unmount_all_stories() -> str:
    """
    Unmount all currently mounted UI preview stories and completely clear the _MCP_Mounted_Stories preview folder.

    Returns:
        JSON response with the number of unmounted stories.
    """
    result = await send_command_to_studio("unmount_all_stories", {})
    return format_result(result)


@mcp.tool()
async def roblox_execute_code(code: str, context: str = "auto") -> str:
    """
    Execute arbitrary Luau code in Roblox Studio with Plugin Security and Command Bar privileges.
    Supports ChangeHistoryService waypoint recording for undo (Ctrl+Z).
    Runs inside a dual-stage compiler (loadstring + ModuleScript Plugin Security fallback).
    Captures prints, warnings, and returned values.

    Args:
        code: The Luau code string to execute.
        context: Execution environment: 'auto' (default: server if playtesting, edit if editing),
                 'server' (explicitly run on Server DataModel), or
                 'client' (explicitly run on Client DataModel / PlayerScripts).

    Returns:
        JSON response with success, captured logs, and return value.
    """
    result = await send_command_to_studio("execute_code", {"code": code, "context": context}, target_context=context)
    return format_result(result)


@mcp.tool()
async def roblox_get_output_logs(max_lines: int = 50, message_type: Optional[str] = None) -> str:
    """
    Get recent log messages from the Roblox Studio Output window via LogService.

    Args:
        max_lines: Maximum number of recent log entries to return (default 50, max 200).
        message_type: Optional filter by message type ("Output", "Info", "Warning", "Error").

    Returns:
        List of log entries with timestamp, messageType, and message.
    """
    result = await send_command_to_studio("get_output_logs", {"max_lines": max_lines, "message_type": message_type})
    return format_result(result)


@mcp.tool()
async def roblox_set_properties(path: str, properties: dict) -> str:
    """
    Set one or more properties on a Roblox instance.
    Automatically handles type conversions for CFrame, Vector3, Color3, BrickColor, UDim2, etc.
    Supported by ChangeHistoryService undo/redo.

    Args:
        path: Dot-separated path to the instance (e.g. "game.Workspace.Part").
        properties: Dictionary of property name to value (e.g. {"Transparency": 0.5, "CanCollide": false, "Color": {"R": 255, "G": 0, "B": 0}}).

    Returns:
        Dictionary with updated property names and any errors.
    """
    result = await send_command_to_studio("set_properties", {"path": path, "properties": properties})
    return format_result(result)


@mcp.tool()
async def roblox_set_attribute(path: str, attribute_name: str, value: Any = None) -> str:
    """
    Set an attribute on a Roblox instance. Pass value=None to remove the attribute.
    Supported by ChangeHistoryService undo/redo.

    Args:
        path: Dot-separated path to the instance (e.g. "game.Workspace.Model").
        attribute_name: Name of the attribute.
        value: Value to set (string, number, boolean, Vector3, Color3, or None to remove).

    Returns:
        Confirmation message with the new attribute value.
    """
    result = await send_command_to_studio("set_attribute", {
        "path": path,
        "attribute_name": attribute_name,
        "value": value,
    })
    return format_result(result)


@mcp.tool()
async def roblox_get_attributes(path: str) -> str:
    """
    Get all attributes of a Roblox instance.

    Args:
        path: Dot-separated path to the instance (e.g. "game.Workspace.Model").

    Returns:
        Dictionary of all attribute names and their serialized values.
    """
    result = await send_command_to_studio("get_attributes", {"path": path})
    return format_result(result)


@mcp.tool()
async def roblox_get_selection() -> str:
    """
    Get the list of instances currently selected by the developer in Roblox Studio.

    Returns:
        List of selected instances with Name, ClassName, and Path.
    """
    result = await send_command_to_studio("get_selection", {})
    return format_result(result)


@mcp.tool()
async def roblox_set_selection(paths: list[str]) -> str:
    """
    Set the active selection in Roblox Studio to the specified instance paths.

    Args:
        paths: List of dot-separated paths to select (e.g. ["game.Workspace.Part1", "game.Workspace.Part2"]).

    Returns:
        List of instances that were successfully selected.
    """
    result = await send_command_to_studio("set_selection", {"paths": paths})
    return format_result(result)


@mcp.tool()
async def focus_on_selection(path: Optional[str] = None) -> str:
    """
    Focus and zoom the Studio viewport camera onto the currently selected instance,
    or onto a specific instance if path is provided.

    Args:
        path: Optional dot-separated path to the instance to focus on.
              If omitted, focuses on the current Studio selection.

    Returns:
        Confirmation message and updated camera position.
    """
    result = await send_command_to_studio("focus_on_selection", {"path": path})
    return format_result(result)


@mcp.tool()
async def roblox_focus_on_selection(path: Optional[str] = None) -> str:
    """
    Alias for focus_on_selection. Focus and zoom the Studio viewport camera onto
    the currently selected instance or specified path.
    """
    return await focus_on_selection(path=path)


# ---------------------------------------------------------------------------
# Playtesting & Autonomous Automation Tools
# ---------------------------------------------------------------------------

@mcp.tool()
async def roblox_get_active_proximity_prompts(max_distance: float = 40.0) -> str:
    """
    Scan for all active and nearby ProximityPrompts in the workspace.
    Returns their path, object text, action text, key code, hold duration, distance from player/camera, and enabled state.
    Use this to see what actions can be interacted with around the character.

    Args:
        max_distance: Maximum distance from player/camera to search (default 40 studs).

    Returns:
        JSON list of nearby ProximityPrompts sorted by distance.
    """
    result = await send_command_to_studio("get_active_proximity_prompts", {"max_distance": max_distance})
    return format_result(result)


@mcp.tool()
async def roblox_trigger_prompt(prompt_path: str, duration: Optional[float] = None) -> str:
    """
    Trigger and hold a ProximityPrompt by its dot-separated path.
    Automatically holds for the required HoldDuration (or override duration).

    Args:
        prompt_path: Dot-separated path to the ProximityPrompt (e.g. "game.Workspace.Car.Prompt").
        duration: Optional hold duration override in seconds. Defaults to prompt.HoldDuration.

    Returns:
        JSON status confirming prompt interaction.
    """
    result = await send_command_to_studio("trigger_prompt", {
        "prompt_path": prompt_path,
        "duration": duration,
    })
    return format_result(result)


@mcp.tool()
async def roblox_simulate_input(
    action: str,
    key: Optional[str] = None,
    x: Optional[int] = None,
    y: Optional[int] = None,
    from_x: Optional[int] = None,
    from_y: Optional[int] = None,
    to_x: Optional[int] = None,
    to_y: Optional[int] = None,
    duration: Optional[float] = None,
    button: Optional[str] = "Left",
    steps: Optional[int] = 10,
) -> str:
    """
    Simulate keyboard, mouse, or touch input via VirtualInputManager.

    Args:
        action: Input type: "key_press", "key_down", "key_up", "mouse_click", "mouse_move", "mouse_drag".
        key: KeyCode name for keyboard actions (e.g. "Space", "W", "A", "S", "D", "E", "F", "Return").
        x: X viewport pixel coordinate for mouse actions.
        y: Y viewport pixel coordinate for mouse actions.
        from_x: Starting X for mouse_drag.
        from_y: Starting Y for mouse_drag.
        to_x: Ending X for mouse_drag.
        to_y: Ending Y for mouse_drag.
        duration: Hold duration for key_press/mouse_click or total duration for mouse_drag.
        button: Mouse button for clicks ("Left" or "Right").
        steps: Interpolation steps for mouse_drag.

    Returns:
        JSON confirmation of simulated input.
    """
    result = await send_command_to_studio("simulate_input", {
        "action": action,
        "key": key,
        "x": x,
        "y": y,
        "from_x": from_x,
        "from_y": from_y,
        "to_x": to_x,
        "to_y": to_y,
        "duration": duration,
        "button": button,
        "steps": steps,
    })
    return format_result(result)


@mcp.tool()
async def roblox_input_sequence(sequence: list[dict]) -> str:
    """
    Execute an ordered batch sequence of input actions with timings in a single round-trip.
    Ideal for walking, jumping, and interacting without multi-turn latency.

    Args:
        sequence: Array of step objects, e.g.:
            [
                {"action": "key_down", "key": "W"},
                {"action": "wait", "duration": 1.5},
                {"action": "key_up", "key": "W"},
                {"action": "key_press", "key": "Space", "duration": 0.05},
                {"action": "mouse_click", "x": 640, "y": 360, "duration": 0.05}
            ]

    Returns:
        JSON confirmation with number of executed steps.
    """
    result = await send_command_to_studio("input_sequence", {"sequence": sequence})
    return format_result(result)


@mcp.tool()
async def roblox_click_ui_element(path: Optional[str] = None, text: Optional[str] = None) -> str:
    """
    Automatically calculate the screen center of a GuiButton in PlayerGui and simulate a mouse click.
    Eliminates manual pixel coordinate guessing across different screen resolutions.

    Args:
        path: Dot-separated path to the GuiObject (e.g. "game.Players.LocalPlayer.PlayerGui.ScreenGui.Button").
        text: Or partial text search on TextButtons/Labels to click (e.g. "Engage", "Cut Wire", "Proceed").

    Returns:
        JSON status with clicked element name and viewport coordinates.
    """
    result = await send_command_to_studio("click_ui_element", {"path": path, "text": text})
    return format_result(result)


@mcp.tool()
async def roblox_world_to_screen(
    path: Optional[str] = None,
    x: Optional[float] = None,
    y: Optional[float] = None,
    z: Optional[float] = None,
) -> str:
    """
    Project a 3D world position or instance into 2D viewport screen coordinates using CurrentCamera.
    Use this to know where a 3D part or NPC is located on your screen to click it.

    Args:
        path: Dot-separated path to a BasePart, Model, or Attachment.
        x: World X coordinate if path is omitted.
        y: World Y coordinate if path is omitted.
        z: World Z coordinate if path is omitted.

    Returns:
        JSON object with screen_x, screen_y, depth, and on_screen boolean.
    """
    pos = {"X": x, "Y": y, "Z": z} if x is not None and y is not None and z is not None else None
    result = await send_command_to_studio("world_to_screen", {"path": path, "position": pos})
    return format_result(result)


@mcp.tool()
async def roblox_look_at(
    target: Optional[str] = None,
    x: Optional[float] = None,
    y: Optional[float] = None,
    z: Optional[float] = None,
) -> str:
    """
    Rotate the Studio CurrentCamera to face directly towards a 3D instance or position.

    Args:
        target: Dot-separated path to the target instance (e.g. "game.Workspace.Car").
        x: Target world X coordinate if target path is omitted.
        y: Target world Y coordinate if target path is omitted.
        z: Target world Z coordinate if target path is omitted.

    Returns:
        JSON status and updated camera CFrame.
    """
    result = await send_command_to_studio("look_at", {"target": target, "x": x, "y": y, "z": z})
    return format_result(result)


@mcp.tool()
async def roblox_set_camera(
    cframe: Optional[dict] = None,
    fov: Optional[float] = None,
) -> str:
    """
    Set the CurrentCamera CFrame and/or FieldOfView.

    Args:
        cframe: Serialized CFrame dictionary (e.g. {"Position": {"X": 0, "Y": 10, "Z": 20}, "Rotation": {"X": 0, "Y": 0, "Z": 0}}).
        fov: Field of view in degrees (e.g. 70).

    Returns:
        JSON status with updated camera state.
    """
    result = await send_command_to_studio("set_camera", {"cframe": cframe, "fov": fov})
    return format_result(result)


@mcp.tool()
async def roblox_teleport(
    target: Optional[str] = None,
    x: Optional[float] = None,
    y: Optional[float] = None,
    z: Optional[float] = None,
    offset_x: float = 0.0,
    offset_y: float = 0.0,
    offset_z: float = 0.0,
    player_name: Optional[str] = None,
) -> str:
    """
    Teleport the player character directly to an instance or world position with an optional offset.

    Args:
        target: Dot-separated path to a BasePart or Model to teleport to (e.g. "game.Workspace.SpawnLocation").
        x: World X coordinate if target path is omitted.
        y: World Y coordinate if target path is omitted.
        z: World Z coordinate if target path is omitted.
        offset_x: Local X offset to apply relative to target.
        offset_y: Local Y offset to apply relative to target (e.g. 3.0 to spawn slightly above ground).
        offset_z: Local Z offset to apply relative to target.
        player_name: Name of player to teleport (defaults to LocalPlayer in Play mode).

    Returns:
        JSON status with new character CFrame.
    """
    pos = {"X": x, "Y": y, "Z": z} if x is not None and y is not None and z is not None else None
    result = await send_command_to_studio("teleport", {
        "target": target,
        "position": pos,
        "offset_x": offset_x,
        "offset_y": offset_y,
        "offset_z": offset_z,
        "player_name": player_name,
    })
    return format_result(result)


@mcp.tool()
async def roblox_equip_tool(tool_name: str, player_name: Optional[str] = None) -> str:
    """
    Equip a tool from the player's Backpack into their Character hands.

    Args:
        tool_name: Name of the tool to equip (e.g. "Fire Hose", "Axe", "Cuffs", "Taser", "Ladder").
        player_name: Optional player name (defaults to LocalPlayer).

    Returns:
        JSON confirmation with equipped tool name.
    """
    result = await send_command_to_studio("equip_tool", {
        "tool_name": tool_name,
        "player_name": player_name,
    })
    return format_result(result)


@mcp.tool()
async def roblox_get_player_state(player_name: Optional[str] = None) -> str:
    """
    Inspect the live state of a player: health, team, position, equipped tool, backpack inventory, and character attributes.

    Args:
        player_name: Optional player name (defaults to LocalPlayer).

    Returns:
        JSON dictionary with player health, position, team, equipped tool, backpack tools, and character attributes.
    """
    result = await send_command_to_studio("get_player_state", {"player_name": player_name})
    return format_result(result)


@mcp.tool()
async def roblox_chat(message: str) -> str:
    """
    Send an in-game chat message or slash command as the LocalPlayer.

    Args:
        message: Chat message text (e.g. "Hello team!", "/e wave", or custom command).

    Returns:
        JSON status confirming chat delivery.
    """
    result = await send_command_to_studio("chat", {"message": message})
    return format_result(result)


@mcp.tool()
async def roblox_wait_for(
    path: str,
    attribute: Optional[str] = None,
    property: Optional[str] = None,
    expected_value: Any = None,
    timeout: float = 10.0,
) -> str:
    """
    Wait until a property or attribute on an instance reaches an expected value (or becomes non-nil).
    Ideal for preventing race conditions during test assertions.

    Args:
        path: Dot-separated path to the instance.
        attribute: Attribute name to poll.
        property: Property name to poll (if attribute is omitted).
        expected_value: Target value to match (or None to wait for non-nil).
        timeout: Maximum wait time in seconds (default 10.0s).

    Returns:
        JSON status with whether the condition matched, current value, and elapsed time.
    """
    result = await send_command_to_studio("wait_for", {
        "path": path,
        "attribute": attribute,
        "property": property,
        "expected_value": expected_value,
        "timeout": timeout,
    })
    return format_result(result)


@mcp.tool()
async def roblox_start_playtest() -> str:
    """
    [DISABLED] Start a Play Solo playtest session in Roblox Studio.
    Temporarily disabled - please press Play (F5) directly in Roblox Studio.
    """
    return json.dumps({
        "success": False,
        "message": "Playtest mode changes via MCP are temporarily disabled. Please press Play (F5) directly in Roblox Studio."
    }, indent=2)


@mcp.tool()
async def roblox_stop_playtest() -> str:
    """
    [DISABLED] Stop the active Play Solo session and return Roblox Studio to Edit Mode.
    Temporarily disabled - please press Stop directly in Roblox Studio.
    """
    return json.dumps({
        "success": False,
        "message": "Playtest mode changes via MCP are temporarily disabled. Please press Stop directly in Roblox Studio."
    }, indent=2)


@mcp.tool()
async def roblox_get_playtest_mode() -> str:
    """
    Get the current Roblox Studio run mode: Edit, PlaySolo, Server, or Client.
    Also returns whether the game is running, whether it is in Edit mode, and elapsed game time.

    Returns:
        JSON status with mode, is_running, is_edit, is_server, is_client, and game_time.
    """
    result = await send_command_to_studio("get_playtest_mode", {})
    return format_result(result)


# ---------------------------------------------------------------------------
# WebSocket Server — runs alongside MCP
# ---------------------------------------------------------------------------

async def handle_studio_websocket(websocket):
    """Handle a WebSocket connection from Roblox Studio."""
    async with connections_lock:
        studio_connections.add(websocket)
        connection_contexts[websocket] = "unknown"
    
    remote = websocket.remote_address
    logger.info(f"✅ Roblox Studio connected from {remote}")

    # Immediately query whoami / mode to discover context
    try:
        whoami_msg = json.dumps({
            "id": f"__whoami_{uuid.uuid4().hex[:8]}",
            "command": "get_playtest_mode",
            "params": {},
        })
        await websocket.send(whoami_msg)
    except Exception as e:
        logger.debug(f"Initial context probe skipped: {e}")

    try:
        async for raw_message in websocket:
            try:
                message = json.loads(raw_message)
            except json.JSONDecodeError:
                logger.warning(f"Invalid JSON from Studio: {raw_message[:200]}")
                continue

            # Update context if provided in message
            ctx = message.get("context")
            if ctx:
                connection_contexts[websocket] = ctx.lower()

            command_id = message.get("id")
            if not command_id:
                # Could be a heartbeat/ping or register
                if message.get("type") in ("ping", "register"):
                    if message.get("type") == "ping":
                        await websocket.send(json.dumps({"type": "pong"}))
                continue

            # Check if this is a response to our initial whoami probe
            if str(command_id).startswith("__whoami_"):
                data = message.get("data", {})
                mode = str(data.get("mode", "")).lower()
                if mode in ("server", "client", "edit"):
                    connection_contexts[websocket] = mode
                    logger.info(f"📌 Identified connection {remote} as [{mode.upper()}]")
                continue

            # Handle client execute requests (from external scripts/agents)
            if message.get("type") == "execute" or "command" in message:
                async with connections_lock:
                    studio_connections.discard(websocket)
                    connection_contexts.pop(websocket, None)
                cmd = message["command"]
                params = message.get("params", {})
                res = await send_command_to_studio(cmd, params)
                await websocket.send(json.dumps({"id": command_id, "result": res}))
                continue

            # This is a response to a pending command from Roblox Studio
            if command_id in pending_commands:
                entry = pending_commands[command_id]
                resp_ctx = message.get("context") or connection_contexts.get(websocket)
                if "error" in message:
                    entry["result"] = {"error": message["error"], "context": resp_ctx}
                else:
                    data = message.get("data", {})
                    if isinstance(data, dict):
                        data["_context"] = resp_ctx
                    entry["result"] = {"data": data, "context": resp_ctx}
                entry["event"].set()
            else:
                logger.warning(f"Received response for unknown command: {command_id}")

    except Exception as e:
        logger.info(f"Studio connection closed: {e}")
    finally:
        async with connections_lock:
            studio_connections.discard(websocket)
            connection_contexts.pop(websocket, None)
        logger.info(f"❌ Roblox Studio disconnected from {remote}")


def free_port(port: int):
    """Ensure port is freed by terminating any orphaned processes listening on it."""
    current_pid = os.getpid()
    
    if sys.platform == "win32":
        try:
            cmd = f'netstat -ano | findstr LISTENING | findstr :{port}'
            output = subprocess.check_output(cmd, shell=True, text=True, errors="ignore")
            for line in output.strip().splitlines():
                parts = line.split()
                if len(parts) >= 5:
                    addr_port = parts[1]
                    listen_port = addr_port.rpartition(":")[2]
                    if listen_port == str(port):
                        pid = int(parts[-1])
                        if pid != current_pid and pid > 0:
                            logger.info(f"Found orphaned process PID {pid} using port {port}. Terminating...")
                            subprocess.run(
                                f"taskkill /F /PID {pid}",
                                shell=True,
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                            )
                            time.sleep(0.5)
        except Exception:
            pass
    else:
        try:
            cmd = f"lsof -t -i:{port}"
            output = subprocess.check_output(cmd, shell=True, text=True, errors="ignore").strip()
            for pid_str in output.split():
                pid = int(pid_str)
                if pid != current_pid and pid > 0:
                    logger.info(f"Found orphaned process PID {pid} using port {port}. Terminating...")
                    os.kill(pid, 9)
                    time.sleep(0.5)
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Vision Bridge Server (Screenshot capture on port 8001)
# ---------------------------------------------------------------------------
_vision_server = None
_vision_thread = None


def is_vision_bridge_running(port: int = 8001) -> bool:
    """Check if the Vision Bridge server is responding to health checks."""
    import urllib.request
    try:
        req = urllib.request.Request(f"http://127.0.0.1:{port}/health", headers={"User-Agent": "FastMCP"})
        with urllib.request.urlopen(req, timeout=1.0) as resp:
            return resp.status == 200
    except Exception:
        return False


def start_vision_bridge_server(port: int = 8001):
    """
    Start the Vision Bridge HTTP server on port 8001 in a daemon thread.
    If already running and healthy, this is a no-op.
    """
    global _vision_server, _vision_thread
    import threading
    import http.server

    if is_vision_bridge_running(port):
        logger.info(f"📸 Vision Bridge is already running on http://127.0.0.1:{port}")
        return True

    try:
        import vision_bridge
    except ImportError as e:
        logger.error(f"Cannot start Vision Bridge: failed to import vision_bridge ({e})")
        return False

    try:
        free_port(port)
        server_address = ("127.0.0.1", port)
        try:
            httpd = http.server.HTTPServer(server_address, vision_bridge.VisionBridgeHandler)
        except OSError as e:
            if getattr(e, "errno", None) in (10048, 98) or "10048" in str(e):
                logger.warning(f"Port {port} busy. Clearing orphan process...")
                free_port(port)
                time.sleep(0.5)
                httpd = http.server.HTTPServer(server_address, vision_bridge.VisionBridgeHandler)
            else:
                raise

        _vision_server = httpd

        def run_server():
            logger.info(f"📸 Vision Bridge HTTP server listening on http://127.0.0.1:{port}")
            try:
                httpd.serve_forever()
            except Exception:
                pass

        _vision_thread = threading.Thread(target=run_server, daemon=True, name="VisionBridgeServer")
        _vision_thread.start()
        time.sleep(0.2)
        return True
    except Exception as e:
        logger.error(f"Failed to start Vision Bridge server on port {port}: {e}")
        return False


def stop_vision_bridge_server():
    """Shut down the Vision Bridge HTTP server if running."""
    global _vision_server
    if _vision_server:
        try:
            _vision_server.shutdown()
            _vision_server.server_close()
        except Exception:
            pass
        _vision_server = None


async def start_websocket_server():
    """Start the WebSocket server on port 8000 with automatic orphan process cleanup."""
    import websockets
    
    # Pre-emptively clear any orphan process listening on port 8000
    free_port(8000)

    for attempt in range(3):
        try:
            server = await websockets.serve(
                handle_studio_websocket,
                "127.0.0.1",
                8000,
                ping_interval=20,
                ping_timeout=10,
            )
            logger.info("🔌 WebSocket server listening on ws://127.0.0.1:8000")
            return server
        except OSError as e:
            if getattr(e, "errno", None) in (10048, 98) or "10048" in str(e):
                logger.warning(f"Port 8000 occupied (attempt {attempt + 1}/3). Clearing orphan process...")
                free_port(8000)
                await asyncio.sleep(0.5)
            else:
                raise

    # Final attempt
    server = await websockets.serve(
        handle_studio_websocket,
        "127.0.0.1",
        8000,
        ping_interval=20,
        ping_timeout=10,
    )
    logger.info("🔌 WebSocket server listening on ws://127.0.0.1:8000")
    return server


# ---------------------------------------------------------------------------
# Entrypoint — run WebSocket server + MCP via stdio
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    async def main():
        # Automatically start Vision Bridge server for screenshots in background
        start_vision_bridge_server(8001)

        # Start WebSocket server in background
        ws_server = await start_websocket_server()

        try:
            # Run MCP server via stdio (Antigravity manages the process)
            await mcp.run_async(transport="stdio")
        finally:
            # Cleanup
            stop_vision_bridge_server()
            ws_server.close()
            await ws_server.wait_closed()

    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("Server shutting down.")
    except Exception as e:
        logger.info(f"Server exiting: {e}")
    finally:
        os._exit(0)
