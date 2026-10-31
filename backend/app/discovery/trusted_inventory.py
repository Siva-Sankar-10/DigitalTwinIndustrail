
import json
import re
import threading

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# Store trusted devices locally on the TwinGuard backend.
DATA_DIR = Path(__file__).resolve().parents[2] / "data"
INVENTORY_FILE = DATA_DIR / "trusted_devices.json"

_lock = threading.RLock()


def normalize_mac(mac_address: str) -> str:
    """Validate and normalize a MAC address."""

    cleaned = re.sub(
        r"[^0-9a-fA-F]",
        "",
        mac_address.strip(),
    )

    if not re.fullmatch(r"[0-9a-fA-F]{12}", cleaned):
        raise ValueError("Invalid MAC address format.")

    first_octet = int(cleaned[:2], 16)

    if first_octet & 1:
        raise ValueError("Multicast MAC addresses cannot be trusted.")

    return ":".join(
        cleaned[index:index + 2].upper()
        for index in range(0, 12, 2)
    )


def _read_inventory() -> list[dict[str, Any]]:
    """Read trusted devices from local JSON storage."""

    if not INVENTORY_FILE.exists():
        return []

    try:
        with INVENTORY_FILE.open("r", encoding="utf-8") as file:
            data = json.load(file)

        if not isinstance(data, list):
            raise ValueError("Trusted inventory must be a list.")

        return data

    except (json.JSONDecodeError, OSError) as error:
        raise RuntimeError(
            "Could not read trusted-device inventory."
        ) from error


def _write_inventory(devices: list[dict[str, Any]]) -> None:
    """Write inventory atomically to avoid partial files."""

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    temporary_file = INVENTORY_FILE.with_suffix(".tmp")

    try:
        with temporary_file.open("w", encoding="utf-8") as file:
            json.dump(
                devices,
                file,
                indent=4,
            )

        temporary_file.replace(INVENTORY_FILE)

    except OSError as error:
        temporary_file.unlink(missing_ok=True)

        raise RuntimeError(
            "Could not save trusted-device inventory."
        ) from error


def get_trusted_devices() -> list[dict[str, Any]]:
    """Return all locally approved devices."""

    with _lock:
        return _read_inventory()


def trust_device(
    mac_address: str,
    device_name: str = "",
) -> dict[str, Any]:
    """Add a device to the approved inventory."""

    mac = normalize_mac(mac_address)

    alias = device_name.strip()

    if len(alias) > 80:
        raise ValueError("Device name must be 80 characters or less.")

    with _lock:
        devices = _read_inventory()

        existing = next(
            (
                device for device in devices
                if device.get("mac_address") == mac
            ),
            None,
        )

        if existing:
            raise ValueError("This device is already trusted.")

        new_device = {
            "mac_address": mac,
            "device_name": alias or "Approved device",
            "created_at": datetime.now(
                timezone.utc
            ).isoformat(),
        }

        devices.append(new_device)

        _write_inventory(devices)

        return new_device


def remove_trusted_device(
    mac_address: str,
) -> bool:
    """Remove a device from the approved inventory."""

    mac = normalize_mac(mac_address)

    with _lock:
        devices = _read_inventory()

        updated_devices = [
            device for device in devices
            if device.get("mac_address") != mac
        ]

        if len(updated_devices) == len(devices):
            return False

        _write_inventory(updated_devices)

        return True


def is_trusted(mac_address: str) -> bool:
    """Check whether a MAC address is approved."""

    mac = normalize_mac(mac_address)

    with _lock:
        return any(
            device.get("mac_address") == mac
            for device in _read_inventory()
        )
