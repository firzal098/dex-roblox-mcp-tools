@echo off
title Roblox Viewport Screenshot Tool
cd /d "%~dp0"
python take_screenshot.py
timeout /t 3
