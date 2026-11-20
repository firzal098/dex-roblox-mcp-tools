"""
Interactive Credential Manager Setup for Roblox Open Cloud API Keys.

Stores API keys encrypted in Windows Credential Manager (via `keyring`)
instead of plaintext inside `.env`. Run this script directly in your terminal:
    python setup_credentials.py
"""

import getpass
import sys

import keyring

KEYRING_SERVICE = "roblox-mcp-tools"
PRIMARY_KEY_NAME = "ROBLOX_OPEN_CLOUD_API_KEY"


def _prompt_and_store(key_name: str, label: str) -> None:
    print(f"\nConfiguring {label} (service='{KEYRING_SERVICE}', key='{key_name}')")
    existing = keyring.get_password(KEYRING_SERVICE, key_name)
    status = "SET" if existing else "NOT SET"
    print(f"Current status: {status}")
    secret = getpass.getpass("Paste API key (input hidden, leave empty to keep unchanged): ").strip()
    if not secret:
        print("No input entered; leaving unchanged.")
        return
    keyring.set_password(KEYRING_SERVICE, key_name, secret)
    print(f"Saved {key_name} to Windows Credential Manager.")


def _check_status() -> None:
    primary = keyring.get_password(KEYRING_SERVICE, PRIMARY_KEY_NAME)
    print(f"\nPrimary key ({PRIMARY_KEY_NAME}): {'SET' if primary else 'NOT SET'}")


def main() -> int:
    print("=== Roblox MCP Tools — Credential Setup ===")
    print("Keys are stored in Windows Credential Manager (encrypted) and never echoed.")

    while True:
        print("\nOptions:")
        print("  1) Set primary ROBLOX_OPEN_CLOUD_API_KEY")
        print("  2) Set per-group override key (ROBLOX_OPEN_CLOUD_KEY_GROUP_<ID>)")
        print("  3) Set per-user override key (ROBLOX_OPEN_CLOUD_KEY_USER_<ID>)")
        print("  4) Delete a stored key")
        print("  5) Check key status")
        print("  0) Exit")

        choice = input("\nSelect option [1]: ").strip() or "1"
        if choice == "1":
            _prompt_and_store(PRIMARY_KEY_NAME, "Primary Open Cloud API Key")
        elif choice == "2":
            gid = input("Enter numeric Group ID: ").strip()
            if gid.isdigit():
                _prompt_and_store(f"ROBLOX_OPEN_CLOUD_KEY_GROUP_{gid}", f"Group {gid} Override Key")
            else:
                print("Invalid numeric Group ID.")
        elif choice == "3":
            uid = input("Enter numeric User ID: ").strip()
            if uid.isdigit():
                _prompt_and_store(f"ROBLOX_OPEN_CLOUD_KEY_USER_{uid}", f"User {uid} Override Key")
            else:
                print("Invalid numeric User ID.")
        elif choice == "4":
            key_name = input(f"Enter key name to delete (e.g. {PRIMARY_KEY_NAME}): ").strip()
            if key_name:
                try:
                    keyring.delete_password(KEYRING_SERVICE, key_name)
                    print(f"Deleted '{key_name}' from Windows Credential Manager.")
                except keyring.errors.PasswordDeleteError:
                    print(f"Key '{key_name}' was not found in Windows Credential Manager.")
        elif choice == "5":
            _check_status()
        elif choice == "0":
            return 0
        else:
            print("Unknown option.")


if __name__ == "__main__":
    sys.exit(main())
