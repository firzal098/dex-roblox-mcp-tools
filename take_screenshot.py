"""
Manual Viewport Screenshot Tool for Roblox Studio VLA Testing.

Usage:
    python take_screenshot.py
    (or double-click take_screenshot.bat)
"""

import json
import os
import sys
from vision_bridge import capture_studio_viewport

def main():
    print("📸 Taking Roblox Studio viewport screenshot...")
    try:
        result = capture_studio_viewport(crop_viewport=True)
        if result.get("success"):
            filepath = result["filepath"]
            width = result["width"]
            height = result["height"]
            print("\n✅ Screenshot captured successfully!")
            print(f"   File: {filepath}")
            print(f"   Dimensions: {width} x {height} px")
            print(f"   Window: {result.get('window_title')}\n")

            # Open image in default Windows image viewer
            try:
                os.startfile(filepath)
            except Exception:
                pass
        else:
            print(f"\n❌ Screenshot failed: {result.get('error')}")
            if result.get("traceback"):
                print(result["traceback"])
    except Exception as e:
        print(f"\n❌ Error: {e}")

if __name__ == "__main__":
    main()
