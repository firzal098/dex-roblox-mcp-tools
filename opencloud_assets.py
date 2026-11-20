"""
Roblox Open Cloud Assets API & Asset Delivery Helpers.

Supports:
- Reading credentials securely from Windows Credential Manager (`keyring`) first,
  with fallback to environment variables / `.env` (for non-secret creator config).
- Multi-group + multi-user creator parsing (`alias:id` or plain numeric IDs) and
  automatic creator selection based on the open Roblox Studio place's `CreatorType`
  and `CreatorId`.
- Uploading images via Open Cloud Assets API v1 (`POST /assets/v1/assets` + polling
  `GET /assets/v1/operations/{operationId}`) with Decal -> Image ID resolution.
- Reading existing image/decal assets by ID via Assets API metadata, Asset Delivery
  API v1 raw download (with Decal XML unwrapping), and Thumbnails API fallback.
"""

from __future__ import annotations

from dataclasses import dataclass
import json
import os
import re
import time
from typing import Any, Optional

from dotenv import load_dotenv
import httpx

try:
    import keyring
except ImportError:  # pragma: no cover
    keyring = None  # type: ignore[assignment]

KEYRING_SERVICE = "roblox-mcp-tools"
OPENCLOUD_ASSETS_BASE = "https://apis.roblox.com/assets/v1"
OPENCLOUD_DELIVERY_BASE = "https://apis.roblox.com/asset-delivery-api/v1"
THUMBNAILS_BASE = "https://thumbnails.roblox.com/v1/assets"

MAX_IMAGE_BYTES = 20 * 1024 * 1024  # 20 MB Open Cloud limit
MAX_IMAGE_DIMENSION = 8000  # < 8000x8000 Open Cloud limit

SUPPORTED_IMAGE_MIMES = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".bmp": "image/bmp",
    ".tga": "image/tga",
}

FORMAT_TO_EXT = {
    "PNG": ".png",
    "JPEG": ".jpg",
    "JPG": ".jpg",
    "BMP": ".bmp",
    "TGA": ".tga",
    "WEBP": ".webp",
}


@dataclass(frozen=True)
class CreatorEntry:
    creator_type: str  # "user" | "group"
    creator_id: str
    alias: Optional[str] = None

    def to_public_dict(self) -> dict[str, Any]:
        return {
            "creator_type": self.creator_type,
            "creator_id": self.creator_id,
            "alias": self.alias,
        }


@dataclass(frozen=True)
class OpenCloudConfig:
    users: list[CreatorEntry]
    groups: list[CreatorEntry]
    default_creator: Optional[str]
    timeout: float
    poll_timeout: float


def _project_root() -> str:
    return os.path.dirname(os.path.abspath(__file__))


def load_env() -> None:
    """Load non-secret / optional config from local .env without overriding OS env vars."""
    dotenv_path = os.path.join(_project_root(), ".env")
    if os.path.exists(dotenv_path):
        load_dotenv(dotenv_path=dotenv_path, override=False)


def _parse_creator_list(raw: str, creator_type: str) -> list[CreatorEntry]:
    entries: list[CreatorEntry] = []
    seen_ids: set[str] = set()
    for token in (raw or "").split(","):
        item = token.strip()
        if not item:
            continue
        alias: Optional[str] = None
        cid = item
        if ":" in item:
            left, right = item.split(":", 1)
            alias = left.strip() or None
            cid = right.strip()
        if not cid.isdigit() or int(cid) <= 0:
            continue
        if cid in seen_ids:
            continue
        seen_ids.add(cid)
        entries.append(CreatorEntry(creator_type=creator_type, creator_id=cid, alias=alias))
    return entries


def load_opencloud_config() -> OpenCloudConfig:
    load_env()
    user_tokens = ",".join(
        part for part in (os.environ.get("ROBLOX_USER_ID", ""), os.environ.get("ROBLOX_USER_IDS", "")) if part.strip()
    )
    group_tokens = ",".join(
        part for part in (os.environ.get("ROBLOX_GROUP_IDS", ""), os.environ.get("ROBLOX_GROUP_ID", "")) if part.strip()
    )
    users = _parse_creator_list(user_tokens, "user")
    groups = _parse_creator_list(group_tokens, "group")

    default_creator = os.environ.get("ROBLOX_DEFAULT_CREATOR", "").strip() or None
    timeout = float(os.environ.get("ROBLOX_OPENCLOUD_TIMEOUT", "30") or 30)
    poll_timeout = float(os.environ.get("ROBLOX_OPENCLOUD_POLL_TIMEOUT", "60") or 60)

    return OpenCloudConfig(
        users=users,
        groups=groups,
        default_creator=default_creator,
        timeout=max(5.0, timeout),
        poll_timeout=max(10.0, poll_timeout),
    )


def _get_secret(key_name: str) -> Optional[str]:
    if keyring is not None:
        try:
            val = keyring.get_password(KEYRING_SERVICE, key_name)
            if val and val.strip():
                return val.strip()
        except Exception:
            pass
    env_val = os.environ.get(key_name, "").strip()
    return env_val or None


def get_api_key(creator_type: Optional[str] = None, creator_id: Optional[str] = None) -> Optional[str]:
    """Resolve API key from Windows Credential Manager (keyring) first, then env/.env."""
    load_env()
    if creator_type and creator_id:
        override_name = f"ROBLOX_OPEN_CLOUD_KEY_{creator_type.upper()}_{creator_id}"
        override = _get_secret(override_name)
        if override:
            return override
    return _get_secret("ROBLOX_OPEN_CLOUD_API_KEY")


def describe_configured_creators() -> dict[str, Any]:
    """Return non-secret summary of configured creators and whether an API key exists."""
    cfg = load_opencloud_config()
    return {
        "has_primary_api_key": bool(get_api_key()),
        "users": [u.to_public_dict() for u in cfg.users],
        "groups": [g.to_public_dict() for g in cfg.groups],
        "default_creator": cfg.default_creator,
    }


def _redact_secrets(text: str) -> str:
    if not text:
        return text
    redacted = text
    cfg = load_opencloud_config()
    candidates = [get_api_key()]
    for entry in [*cfg.users, *cfg.groups]:
        candidates.append(get_api_key(entry.creator_type, entry.creator_id))
    for secret in candidates:
        if secret and len(secret) >= 6:
            redacted = redacted.replace(secret, "[REDACTED_API_KEY]")
    return redacted


def _match_entry(entries: list[CreatorEntry], query: str) -> Optional[CreatorEntry]:
    q = query.strip().lower()
    for entry in entries:
        if entry.creator_id == q or (entry.alias and entry.alias.lower() == q):
            return entry
    return None


def _parse_default_creator_spec(spec: str, cfg: OpenCloudConfig) -> Optional[CreatorEntry]:
    s = spec.strip()
    if not s:
        return None
    low = s.lower()
    if low == "user":
        return cfg.users[0] if len(cfg.users) == 1 else None
    if low == "group":
        return cfg.groups[0] if len(cfg.groups) == 1 else None
    if ":" in s:
        kind, target = s.split(":", 1)
        kind_low = kind.strip().lower()
        target = target.strip()
        if kind_low == "user":
            return _match_entry(cfg.users, target) or (
                CreatorEntry("user", target) if target.isdigit() else None
            )
        if kind_low == "group":
            return _match_entry(cfg.groups, target) or (
                CreatorEntry("group", target) if target.isdigit() else None
            )
    return _match_entry(cfg.groups, s) or _match_entry(cfg.users, s)


def resolve_upload_creator(
    creator_type: str = "auto",
    creator_id: Optional[str] = None,
    place_info: Optional[dict[str, Any]] = None,
    config: Optional[OpenCloudConfig] = None,
) -> tuple[CreatorEntry, str]:
    """
    Resolve the target creator (userId or groupId) for an upload.
    Returns (CreatorEntry, reason_string).
    """
    cfg = config or load_opencloud_config()
    ctype = (creator_type or "auto").strip().lower()

    if ctype in ("user", "group"):
        entries = cfg.users if ctype == "user" else cfg.groups
        if creator_id:
            matched = _match_entry(entries, str(creator_id))
            if matched:
                return matched, f"explicit {ctype} '{matched.alias or matched.creator_id}'"
            cid = str(creator_id).strip()
            if cid.isdigit() and int(cid) > 0:
                return CreatorEntry(ctype, cid), f"explicit {ctype} ID {cid}"
            available = [e.to_public_dict() for e in entries]
            raise ValueError(
                f"Creator '{creator_id}' did not match any configured {ctype} ID/alias. Configured {ctype}s: {available}"
            )
        if len(entries) == 1:
            only = entries[0]
            return only, f"sole configured {ctype} '{only.alias or only.creator_id}'"
        if not entries:
            raise ValueError(
                f"No {ctype} IDs configured in .env. Set ROBLOX_{'USER_ID' if ctype == 'user' else 'GROUP_IDS'} or pass creator_id."
            )
        raise ValueError(
            f"Multiple {ctype}s configured; pass creator_id (ID or alias): {[e.to_public_dict() for e in entries]}"
        )

    if ctype != "auto":
        raise ValueError(f"Invalid creator_type '{creator_type}'. Use 'auto', 'user', or 'group'.")

    # Auto mode: inspect live Studio place ownership
    if place_info and place_info.get("creator_id"):
        place_cid = str(place_info["creator_id"])
        place_ctype = str(place_info.get("creator_type", "")).strip().lower()
        place_group_name = place_info.get("group_name")

        if place_ctype == "group" and int(place_cid) > 0:
            matched = _match_entry(cfg.groups, place_cid)
            if matched:
                label = matched.alias or place_group_name or matched.creator_id
                return matched, f"auto-matched active Studio Group place ({label}, groupId={place_cid})"
            raise ValueError(
                f"Active Studio place is owned by Group '{place_group_name or place_cid}' (groupId={place_cid}), "
                f"which is not in ROBLOX_GROUP_IDS. Configured targets: {describe_configured_creators()}. "
                f"Add {place_cid} to ROBLOX_GROUP_IDS in .env or pass creator_type/creator_id explicitly."
            )

        if place_ctype == "user" and int(place_cid) > 0:
            matched = _match_entry(cfg.users, place_cid)
            if matched:
                return matched, f"auto-matched active Studio User place (userId={place_cid})"
            if not cfg.users:
                return CreatorEntry("user", place_cid), f"auto-detected active Studio User place (userId={place_cid})"
            raise ValueError(
                f"Active Studio place is owned by User ID {place_cid}, which does not match configured "
                f"ROBLOX_USER_ID(S) {[u.to_public_dict() for u in cfg.users]}. Pass creator_type/creator_id explicitly."
            )

    # Unpublished local place (CreatorId == 0) or Studio disconnected
    if cfg.default_creator:
        parsed = _parse_default_creator_spec(cfg.default_creator, cfg)
        if parsed:
            return parsed, f"ROBLOX_DEFAULT_CREATOR='{cfg.default_creator}' (place unpublished or Studio disconnected)"
        raise ValueError(
            f"ROBLOX_DEFAULT_CREATOR='{cfg.default_creator}' did not resolve to a valid user/group. "
            f"Configured targets: {describe_configured_creators()}"
        )

    all_targets = [*cfg.users, *cfg.groups]
    if len(all_targets) == 1:
        only = all_targets[0]
        return only, f"sole configured creator ({only.creator_type}={only.creator_id})"
    if len(cfg.users) == 1 and not cfg.groups:
        only = cfg.users[0]
        return only, f"default personal userId={only.creator_id}"

    raise ValueError(
        "Cannot auto-select creator because the open place is unpublished (CreatorId=0) or Studio is disconnected, "
        f"and multiple targets or no ROBLOX_DEFAULT_CREATOR are configured. Configured targets: {describe_configured_creators()}. "
        "Pass creator_type='user'|'group' and creator_id explicitly, or set ROBLOX_DEFAULT_CREATOR in .env."
    )


def normalize_asset_id(raw_id: Any) -> str:
    text = str(raw_id or "").strip()
    if text.isdigit():
        return text
    match = re.search(r"(?:rbxassetid://|[?&]id=|/assets/|/assetId/)(\d+)", text, flags=re.IGNORECASE)
    if match:
        return match.group(1)
    digits = re.findall(r"\d+", text)
    if len(digits) == 1:
        return digits[0]
    raise ValueError(f"Could not parse numeric Roblox asset ID from '{raw_id}'.")


def validate_image_file(file_path: str) -> dict[str, Any]:
    abs_path = os.path.abspath(os.path.expanduser(file_path))
    if not os.path.isfile(abs_path):
        raise FileNotFoundError(f"Image file not found: {abs_path}")

    ext = os.path.splitext(abs_path)[1].lower()
    mime = SUPPORTED_IMAGE_MIMES.get(ext)
    if not mime:
        raise ValueError(
            f"Unsupported image extension '{ext}'. Supported: {', '.join(sorted(SUPPORTED_IMAGE_MIMES))}"
        )

    size_bytes = os.path.getsize(abs_path)
    if size_bytes == 0:
        raise ValueError(f"Image file is empty: {abs_path}")
    if size_bytes > MAX_IMAGE_BYTES:
        raise ValueError(f"Image file exceeds 20 MB Open Cloud limit ({size_bytes} bytes): {abs_path}")

    width: Optional[int] = None
    height: Optional[int] = None
    try:
        from PIL import Image as PILImage
        with PILImage.open(abs_path) as img:
            width, height = img.size
        if width >= MAX_IMAGE_DIMENSION or height >= MAX_IMAGE_DIMENSION:
            raise ValueError(
                f"Image dimensions {width}x{height} exceed Open Cloud limit (< {MAX_IMAGE_DIMENSION}x{MAX_IMAGE_DIMENSION})."
            )
    except ImportError:
        pass

    return {
        "abs_path": abs_path,
        "filename": os.path.basename(abs_path),
        "mime_type": mime,
        "size_bytes": size_bytes,
        "width": width,
        "height": height,
    }


def _extract_decal_texture_id(payload: bytes) -> Optional[str]:
    """If downloaded payload is a Roblox XML Decal wrapper, extract the underlying Texture Image ID."""
    head = payload[:512].lstrip()
    if not head.startswith(b"<roblox"):
        return None
    try:
        text = payload.decode("utf-8", errors="ignore")
    except Exception:
        return None
    match = re.search(
        r'<Content\s+name="Texture"[^>]*>.*?<(?:url|uri)>\s*(?:https?://www\.roblox\.com/asset/\?id=|rbxassetid://)(\d+)\s*</(?:url|uri)>',
        text,
        flags=re.IGNORECASE | re.DOTALL,
    )
    if match:
        return match.group(1)
    fallback = re.search(r"(?:rbxassetid://|[?&]id=)(\d+)", text, flags=re.IGNORECASE)
    return fallback.group(1) if fallback else None


def _detect_image_metadata(raw_bytes: bytes) -> tuple[Optional[str], Optional[int], Optional[int]]:
    try:
        from io import BytesIO
        from PIL import Image as PILImage
        with PILImage.open(BytesIO(raw_bytes)) as img:
            fmt = (img.format or "PNG").upper()
            w, h = img.size
            return fmt, w, h
    except Exception:
        if raw_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
            return "PNG", None, None
        if raw_bytes.startswith(b"\xff\xd8\xff"):
            return "JPEG", None, None
        if raw_bytes.startswith(b"BM"):
            return "BMP", None, None
        return None, None, None


def _fetch_raw_asset_bytes(
    client: httpx.Client,
    asset_id: str,
    api_key: str,
) -> tuple[bytes, Optional[str]]:
    """
    Download raw asset bytes via Open Cloud Asset Delivery API.
    If asset_id points to a Decal XML wrapper, automatically resolves and downloads
    the underlying Image asset bytes, returning (bytes, unwrapped_image_id).
    """
    headers = {"x-api-key": api_key}
    resp = client.get(f"{OPENCLOUD_DELIVERY_BASE}/assetId/{asset_id}", headers=headers)
    if resp.status_code >= 400:
        raise httpx.HTTPStatusError(
            f"Asset Delivery API returned {resp.status_code}: {resp.text[:300]}",
            request=resp.request,
            response=resp,
        )

    data = resp.json()
    location = data.get("location")
    if not location:
        raise RuntimeError(f"Asset Delivery API response missing 'location': {data}")

    dl_resp = client.get(location)
    dl_resp.raise_for_status()
    raw_bytes = dl_resp.content

    inner_image_id = _extract_decal_texture_id(raw_bytes)
    if inner_image_id and inner_image_id != asset_id:
        inner_resp = client.get(f"{OPENCLOUD_DELIVERY_BASE}/assetId/{inner_image_id}", headers=headers)
        if inner_resp.status_code < 400:
            inner_loc = inner_resp.json().get("location")
            if inner_loc:
                inner_dl = client.get(inner_loc)
                inner_dl.raise_for_status()
                return inner_dl.content, inner_image_id

    return raw_bytes, None


def upload_image_asset(
    file_path: str,
    display_name: Optional[str] = None,
    description: str = "",
    asset_type: str = "Decal",
    creator_type: str = "auto",
    creator_id: Optional[str] = None,
    expected_price: int = 0,
    wait_for_completion: bool = True,
    place_info: Optional[dict[str, Any]] = None,
    transport: Optional[httpx.BaseTransport] = None,
) -> dict[str, Any]:
    """Upload a local image to Roblox via Open Cloud Assets API v1."""
    cfg = load_opencloud_config()
    info = validate_image_file(file_path)
    creator, resolution_reason = resolve_upload_creator(
        creator_type=creator_type,
        creator_id=creator_id,
        place_info=place_info,
        config=cfg,
    )

    api_key = get_api_key(creator.creator_type, creator.creator_id)
    if not api_key:
        raise ValueError(
            "ROBLOX_OPEN_CLOUD_API_KEY is not configured. Run `python setup_credentials.py` in your terminal "
            "(recommended, stores in Windows Credential Manager) or set ROBLOX_OPEN_CLOUD_API_KEY in .env."
        )

    normalized_type = asset_type.strip().capitalize()
    if normalized_type not in ("Decal", "Image"):
        raise ValueError(f"Unsupported asset_type '{asset_type}'. Must be 'Decal' or 'Image'.")

    title = (display_name or os.path.splitext(info["filename"])[0]).strip()[:50]
    creator_obj = (
        {"groupId": creator.creator_id}
        if creator.creator_type == "group"
        else {"userId": creator.creator_id}
    )

    request_payload: dict[str, Any] = {
        "assetType": normalized_type,
        "displayName": title,
        "description": description or "",
        "creationContext": {
            "creator": creator_obj,
            "expectedPrice": int(expected_price),
        },
    }

    try:
        with httpx.Client(timeout=cfg.timeout, transport=transport) as client:
            with open(info["abs_path"], "rb") as fh:
                files = {
                    "request": (None, json.dumps(request_payload), "application/json"),
                    "fileContent": (info["filename"], fh, info["mime_type"]),
                }
                resp = client.post(
                    f"{OPENCLOUD_ASSETS_BASE}/assets",
                    headers={"x-api-key": api_key},
                    files=files,
                )

            if resp.status_code >= 400:
                raise RuntimeError(f"Open Cloud upload failed ({resp.status_code}): {resp.text[:500]}")

            op_data = resp.json()
            op_path = op_data.get("path", "")
            operation_id = op_path.split("/")[-1] if op_path else op_data.get("operationId", "")

            if not wait_for_completion or op_data.get("done") is True:
                asset_resp = op_data.get("response") or {}
            else:
                if not operation_id:
                    raise RuntimeError(f"Open Cloud response missing operation path: {op_data}")
                deadline = time.monotonic() + cfg.poll_timeout
                delay = 1.0
                while True:
                    poll = client.get(
                        f"{OPENCLOUD_ASSETS_BASE}/operations/{operation_id}",
                        headers={"x-api-key": api_key},
                    )
                    if poll.status_code >= 400:
                        raise RuntimeError(f"Operation poll failed ({poll.status_code}): {poll.text[:500]}")
                    op_data = poll.json()
                    if op_data.get("done"):
                        break
                    if time.monotonic() >= deadline:
                        return {
                            "success": False,
                            "pending": True,
                            "operation_id": operation_id,
                            "operation_path": op_path,
                            "creator": creator.to_public_dict(),
                            "creator_resolution": resolution_reason,
                            "message": f"Upload submitted but polling timed out after {cfg.poll_timeout}s.",
                        }
                    time.sleep(delay)
                    delay = min(3.0, delay + 0.5)

                if "error" in op_data:
                    raise RuntimeError(f"Open Cloud operation error: {op_data['error']}")
                asset_resp = op_data.get("response") or {}

            asset_id = str(asset_resp.get("assetId", "") or "").strip()
            image_asset_id: Optional[str] = None

            if asset_id and normalized_type == "Image":
                image_asset_id = asset_id
            elif asset_id and normalized_type == "Decal":
                try:
                    _, unwrapped_id = _fetch_raw_asset_bytes(client, asset_id, api_key)
                    image_asset_id = unwrapped_id
                except Exception:
                    image_asset_id = None

            moderation = asset_resp.get("moderationResult") or {}
            return {
                "success": True,
                "asset_id": asset_id or None,
                "asset_type": asset_resp.get("assetType", normalized_type),
                "image_asset_id": image_asset_id,
                "rbxassetid": f"rbxassetid://{image_asset_id or asset_id}" if asset_id else None,
                "decal_rbxassetid": f"rbxassetid://{asset_id}" if (asset_id and normalized_type == "Decal") else None,
                "display_name": asset_resp.get("displayName", title),
                "moderation_state": moderation.get("moderationState"),
                "revision_id": asset_resp.get("revisionId"),
                "operation_id": operation_id or None,
                "creator": creator.to_public_dict(),
                "creator_resolution": resolution_reason,
                "source_file": info["abs_path"],
                "width": info["width"],
                "height": info["height"],
            }
    except Exception as exc:
        raise RuntimeError(_redact_secrets(str(exc))) from exc


def get_image_asset(
    asset_id: str,
    output_path: Optional[str] = None,
    download_image: bool = True,
    thumbnail_size: str = "420x420",
    allow_thumbnail_fallback: bool = True,
    transport: Optional[httpx.BaseTransport] = None,
) -> dict[str, Any]:
    """Read metadata and download image bytes for an existing Roblox asset ID (Decal or Image)."""
    cfg = load_opencloud_config()
    clean_id = normalize_asset_id(asset_id)
    api_key = get_api_key()

    metadata: Optional[dict[str, Any]] = None
    metadata_error: Optional[str] = None

    try:
        with httpx.Client(timeout=cfg.timeout, transport=transport) as client:
            # 1. Open Cloud Asset Metadata (non-fatal if unowned or key missing)
            if api_key:
                meta_resp = client.get(
                    f"{OPENCLOUD_ASSETS_BASE}/assets/{clean_id}",
                    headers={"x-api-key": api_key},
                )
                if meta_resp.status_code < 400:
                    metadata = meta_resp.json()
                else:
                    metadata_error = f"Metadata HTTP {meta_resp.status_code}: {meta_resp.text[:250]}"
            else:
                metadata_error = "No Open Cloud API key configured; skipping private metadata/delivery."

            if not download_image:
                return {
                    "success": True,
                    "asset_id": clean_id,
                    "rbxassetid": f"rbxassetid://{clean_id}",
                    "metadata": metadata,
                    "metadata_error": _redact_secrets(metadata_error or "") or None,
                }

            raw_bytes: Optional[bytes] = None
            unwrapped_image_id: Optional[str] = None
            delivery_error: Optional[str] = None
            source = "asset_delivery_api"

            # 2. Raw Asset Delivery API (supports private/owned Decals & Images + unwraps Decal XML)
            if api_key:
                try:
                    raw_bytes, unwrapped_image_id = _fetch_raw_asset_bytes(client, clean_id, api_key)
                except Exception as exc:
                    delivery_error = str(exc)

            # 3. Public Thumbnails API Fallback
            if raw_bytes is None and allow_thumbnail_fallback:
                thumb_resp = client.get(
                    THUMBNAILS_BASE,
                    params={
                        "assetIds": clean_id,
                        "size": thumbnail_size,
                        "format": "Png",
                        "isCircular": "false",
                    },
                )
                if thumb_resp.status_code >= 400:
                    raise RuntimeError(
                        f"Asset Delivery failed ({delivery_error}) and Thumbnails API returned {thumb_resp.status_code}: {thumb_resp.text[:300]}"
                    )
                thumb_data = (thumb_resp.json().get("data") or [])
                entry = thumb_data[0] if thumb_data else {}
                image_url = entry.get("imageUrl")
                if not image_url or entry.get("state") != "Completed":
                    raise RuntimeError(
                        f"Thumbnail not ready/available for asset {clean_id} (state={entry.get('state')}, delivery_error={delivery_error})"
                    )
                img_dl = client.get(image_url)
                img_dl.raise_for_status()
                raw_bytes = img_dl.content
                source = "thumbnails_api_fallback"

            if raw_bytes is None:
                raise RuntimeError(delivery_error or f"Could not download asset {clean_id}.")

            fmt, width, height = _detect_image_metadata(raw_bytes)
            ext = FORMAT_TO_EXT.get(fmt or "", ".png")

            resolved_id = unwrapped_image_id or clean_id
            if output_path:
                dest_path = os.path.abspath(os.path.expanduser(output_path))
                os.makedirs(os.path.dirname(dest_path), exist_ok=True)
            else:
                cache_dir = os.path.join(_project_root(), "assets_cache")
                os.makedirs(cache_dir, exist_ok=True)
                prefix = "thumb" if source == "thumbnails_api_fallback" else "asset"
                dest_path = os.path.join(cache_dir, f"{prefix}_{resolved_id}{ext}")

            with open(dest_path, "wb") as out_fh:
                out_fh.write(raw_bytes)

            return {
                "success": True,
                "asset_id": clean_id,
                "resolved_image_asset_id": unwrapped_image_id,
                "rbxassetid": f"rbxassetid://{resolved_id}",
                "filepath": dest_path,
                "filename": os.path.basename(dest_path),
                "format": fmt,
                "width": width,
                "height": height,
                "byte_length": len(raw_bytes),
                "source": source,
                "metadata": metadata,
                "metadata_error": _redact_secrets(metadata_error or "") or None,
                "delivery_error": _redact_secrets(delivery_error or "") or None,
            }
    except Exception as exc:
        raise RuntimeError(_redact_secrets(str(exc))) from exc
