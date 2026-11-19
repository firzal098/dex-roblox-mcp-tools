"""
Roblox Studio Vision Bridge for VLA (Vision-Language-Action) Testing.

This script runs in the user's interactive desktop session (Session 1)
to capture the Roblox Studio viewport/window and expose a local HTTP endpoint
for the FastMCP server (server.py).

Usage:
    python vision_bridge.py
"""

import ctypes
from ctypes import wintypes
import http.server
import json
import os
import sys
import time
import subprocess
from PIL import ImageGrab

# Enable Per-Monitor High DPI awareness so Windows returns physical screen pixel resolution
try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except Exception:
    try:
        ctypes.windll.user32.SetProcessDPIAware()
    except Exception:
        pass

PORT = 8001
OUTPUT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "screenshots"))
os.makedirs(OUTPUT_DIR, exist_ok=True)

user32 = ctypes.windll.user32

def find_roblox_studio_window():
    """Find the Roblox Studio window handle and bounds by title or process name."""
    studio_windows = []

    def enum_cb(hwnd, lparam):
        if user32.IsWindowVisible(hwnd):
            length = user32.GetWindowTextLengthW(hwnd)
            buf = ctypes.create_unicode_buffer(length + 1)
            if length > 0:
                user32.GetWindowTextW(hwnd, buf, length + 1)
            title = buf.value.lower()

            # Check by PID process image name
            is_roblox_proc = False
            pid = wintypes.DWORD()
            user32.GetWindowThreadProcessId(hwnd, ctypes.byref(pid))
            if pid.value:
                # PROCESS_QUERY_LIMITED_INFORMATION = 0x1000
                hproc = ctypes.windll.kernel32.OpenProcess(0x1000, False, pid.value)
                if hproc:
                    buf_proc = ctypes.create_unicode_buffer(512)
                    size = wintypes.DWORD(512)
                    if ctypes.windll.kernel32.QueryFullProcessImageNameW(hproc, 0, buf_proc, ctypes.byref(size)):
                        if "robloxstudio" in buf_proc.value.lower():
                            is_roblox_proc = True
                    ctypes.windll.kernel32.CloseHandle(hproc)

            # Exclude code editors, IDEs, and web browsers
            is_ide = any(ex in title for ex in ["antigravity", "visual studio", "vscode", "ide", "code -", "chrome", "edge", "firefox"])

            # Must be RobloxStudio process OR strictly contain "roblox studio" (and not be an IDE window)
            is_studio_title = ("roblox studio" in title or "robloxstudio" in title) and not is_ide

            if is_roblox_proc or is_studio_title:
                is_iconic = bool(user32.IsIconic(hwnd))
                rect = wintypes.RECT()
                user32.GetWindowRect(hwnd, ctypes.byref(rect))
                width = rect.right - rect.left
                height = rect.bottom - rect.top
                if (width > 300 and height > 300) or is_iconic:
                    studio_windows.append({
                        "hwnd": hwnd,
                        "title": buf.value if buf.value else "Roblox Studio",
                        "bbox": (rect.left, rect.top, rect.right, rect.bottom),
                        "width": 1920 if is_iconic else width,
                        "height": 1080 if is_iconic else height,
                        "is_iconic": is_iconic
                    })
        return True

    WNDENUMPROC = ctypes.WINFUNCTYPE(ctypes.c_bool, wintypes.HWND, wintypes.LPARAM)
    user32.EnumWindows(WNDENUMPROC(enum_cb), 0)

    if not studio_windows:
        hdesk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
        if hdesk:
            user32.EnumDesktopWindows(hdesk, WNDENUMPROC(enum_cb), 0)
            user32.CloseDesktop(hdesk)

    # Sort by window area descending to get the main window
    studio_windows.sort(key=lambda w: w["width"] * w["height"], reverse=True)
    return studio_windows[0] if studio_windows else None


def capture_studio_viewport(crop_viewport: bool = False):
    """Capture the Roblox Studio window and save it to disk."""
    hdesk = user32.OpenDesktopW("Default", 0, False, 0x01FF)
    if hdesk:
        user32.SetThreadDesktop(hdesk)

    win_info = find_roblox_studio_window()
    if not win_info:
        raise RuntimeError("Roblox Studio window not found. Please ensure Roblox Studio is open on your screen.")

    hwnd = win_info["hwnd"]
    # Only restore if minimized (IsIconic). Do NOT un-maximize if already maximized/visible!
    if user32.IsIconic(hwnd):
        user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetForegroundWindow(hwnd)
    time.sleep(0.15)  # Allow OS time to repaint window

    # Re-fetch bounding rect after restore
    rect = wintypes.RECT()
    user32.GetWindowRect(hwnd, ctypes.byref(rect))
    bbox = (rect.left, rect.top, rect.right, rect.bottom)
    win_title = win_info["title"]

    try:
        img = None

        # Method 1: Direct Win32 PrintWindow (Captures ONLY Roblox Studio window buffer, ignoring overlapping windows like IDE)
        try:
            gdi32 = ctypes.windll.gdi32
            rect = wintypes.RECT()
            user32.GetWindowRect(hwnd, ctypes.byref(rect))
            w = rect.right - rect.left
            h = rect.bottom - rect.top

            if w > 0 and h > 0:
                hdc_window = user32.GetWindowDC(hwnd)
                hdc_mem = gdi32.CreateCompatibleDC(hdc_window)
                hbmp = gdi32.CreateCompatibleBitmap(hdc_window, w, h)
                gdi32.SelectObject(hdc_mem, hbmp)

                # PW_RENDERFULLCONTENT = 2
                res = user32.PrintWindow(hwnd, hdc_mem, 2)

                class BITMAPINFOHEADER(ctypes.Structure):
                    _fields_ = [
                        ('biSize', wintypes.DWORD),
                        ('biWidth', wintypes.LONG),
                        ('biHeight', wintypes.LONG),
                        ('biPlanes', wintypes.WORD),
                        ('biBitCount', wintypes.WORD),
                        ('biCompression', wintypes.DWORD),
                        ('biSizeImage', wintypes.DWORD),
                        ('biXPelsPerMeter', wintypes.LONG),
                        ('biYPelsPerMeter', wintypes.LONG),
                        ('biClrUsed', wintypes.DWORD),
                        ('biClrImportant', wintypes.DWORD),
                    ]

                bmi = BITMAPINFOHEADER()
                bmi.biSize = ctypes.sizeof(BITMAPINFOHEADER)
                bmi.biWidth = w
                bmi.biHeight = -h  # top-down
                bmi.biPlanes = 1
                bmi.biBitCount = 32

                buf = ctypes.create_string_buffer(w * h * 4)
                gdi32.GetDIBits(hdc_mem, hbmp, 0, h, buf, ctypes.byref(bmi), 0)

                from PIL import Image as PILImage
                captured = PILImage.frombuffer('RGBA', (w, h), buf.raw, 'raw', 'BGRA', 0, 1)

                gdi32.DeleteObject(hbmp)
                gdi32.DeleteDC(hdc_mem)
                user32.ReleaseDC(hwnd, hdc_window)

                # Verify image is not pure black/empty
                if captured and captured.getbbox():
                    img = captured.convert("RGB")
        except Exception as e:
            print(f"[Vision Bridge] PrintWindow attempt failed: {e}")

        # Method 2: Fallback to Screen Region (MSS)
        if img is None:
            try:
                import mss
                from PIL import Image as PILImage
                with mss.MSS() as sct:
                    if bbox:
                        left, top, right, bottom = bbox
                        mon = {"left": left, "top": top, "width": max(1, right - left), "height": max(1, bottom - top)}
                    else:
                        mon = sct.monitors[1]
                    sct_img = sct.grab(mon)
                    img = PILImage.frombytes("RGB", sct_img.size, sct_img.bgra, "raw", "BGRX")
            except Exception:
                pass

        # Method 3: Fallback to PIL ImageGrab
        if img is None:
            try:
                if bbox:
                    img = ImageGrab.grab(bbox=bbox)
                else:
                    img = ImageGrab.grab()
            except Exception:
                pass

        if img is None:
            raise RuntimeError("Screen grab returned empty image.")

        # Auto-crop strictly to the 3D Viewport canvas (stripping toolbars, Explorer, sidebars, status bar)
        if crop_viewport:
            w, h = img.size
            top_margin = int(h * 0.215)     # ~24.5% (title bar, ribbon bar, document tab)
            bottom_margin = int(h * 0.075)  # ~7.5% (command execution bar & status bar)
            right_margin = int(w * 0.292)   # ~29.2% (Explorer, Properties, and Assistant panels)
            left_margin = int(w * 0.005)    # ~0.5% (left border)

            crop_box = (left_margin, top_margin, w - right_margin, h - bottom_margin)
            img = img.crop(crop_box)

        filename = f"roblox_viewport_{int(time.time())}.png"
        filepath = os.path.join(OUTPUT_DIR, filename)
        img.save(filepath)

        return {
            "success": True,
            "filepath": filepath,
            "filename": filename,
            "width": img.width,
            "height": img.height,
            "window_title": win_title
        }
    except Exception as e:
        import traceback
        tb = traceback.format_exc()
        print(f"[Vision Bridge Error] {e}\n{tb}")
        return {
            "success": False,
            "error": str(e),
            "traceback": tb
        }


class VisionBridgeHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        from urllib.parse import urlparse, parse_qs
        parsed = urlparse(self.path)
        if parsed.path in ["/screenshot", "/capture"]:
            qs = parse_qs(parsed.query)
            crop_param = qs.get("crop", [""])[0].lower()
            if crop_param in ("1", "true", "yes"):
                crop = True
            elif crop_param in ("0", "false", "no"):
                crop = False
            else:
                crop = True if parsed.path == "/capture" else False
            result = capture_studio_viewport(crop_viewport=crop)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(result).encode("utf-8"))
        elif parsed.path == "/health":
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"status": "ok", "service": "Roblox Vision Bridge"}).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Quiet logging


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
                            print(f"[Vision Bridge] Found orphaned process PID {pid} using port {port}. Terminating...")
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
                    print(f"[Vision Bridge] Found orphaned process PID {pid} using port {port}. Terminating...")
                    os.kill(pid, 9)
                    time.sleep(0.5)
        except Exception:
            pass


def main():
    free_port(PORT)
    server_address = ("127.0.0.1", PORT)
    try:
        httpd = http.server.HTTPServer(server_address, VisionBridgeHandler)
    except OSError as e:
        if getattr(e, "errno", None) in (10048, 98) or "10048" in str(e):
            print(f"[Vision Bridge] Port {PORT} busy. Clearing orphan process...")
            free_port(PORT)
            time.sleep(0.5)
            httpd = http.server.HTTPServer(server_address, VisionBridgeHandler)
        else:
            raise

    print(f"[Vision Bridge] Roblox Studio Vision Bridge running on http://127.0.0.1:{PORT}")
    print(f"[Vision Bridge] Screenshots directory: {OUTPUT_DIR}")
    print("[Vision Bridge] Press Ctrl+C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down Vision Bridge.")
        httpd.server_close()
        sys.exit(0)


if __name__ == "__main__":
    main()
