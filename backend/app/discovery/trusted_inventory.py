
import json
import re
import threading

from datetime import datetime, timezone
from pathlib import Path
from typing import Any


# New network-specific inventory.
# The old trusted_devices.json file is deliberately preserved.
DATA_DIR = Path(__file__).resolve().parents[2] / "data"

INVENTORY_FILE = DATA_DIR / "trusted_devices_by_network.json"
LEGACY_INVENTORY_FILE = DATA_DIR / "trusted_devices.json"

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


def _normalize_network_id(network_id: str) -> str:
    """Validate a network fingerprint."""

    if not isinstance(network_id, str):
        raise ValueError("A valid network ID is required.")

    normalized = network_id.strip()

    if not normalized or len(normalized) > 256:
        raise ValueError("A valid network ID is required.")

    return normalized


def _empty_inventory() -> dict[str, Any]:
    return {
        "version": 1,
        "networks": {},
    }


def _read_inventory() -> dict[str, Any]:
    """Read network-specific trusted devices."""

    if not INVENTORY_FILE.exists():
        return _empty_inventory()

    try:
        with INVENTORY_FILE.open("r", encoding="utf-8") as file:
            data = json.load(file)

        if (
            not isinstance(data, dict)
            or data.get("version") != 1
            or not isinstance(data.get("networks"), dict)
        ):
            raise ValueError("Invalid network-specific inventory format.")

        for network_id, devices in data["networks"].items():
            if not isinstance(network_id, str) or not isinstance(devices, list):
                raise ValueError("Invalid network inventory entry.")

        return data

    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise RuntimeError(
            "Could not read network-specific trusted-device inventory."
        ) from error


def _write_inventory(inventory: dict[str, Any]) -> None:
    """Write inventory atomically."""

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    temporary_file = INVENTORY_FILE.with_suffix(".tmp")

    try:
        with temporary_file.open("w", encoding="utf-8") as file:
            json.dump(inventory, file, indent=4)

        temporary_file.replace(INVENTORY_FILE)

    except OSError as error:
        temporary_file.unlink(missing_ok=True)

        raise RuntimeError(
            "Could not save network-specific trusted-device inventory."
        ) from error


def get_trusted_devices(network_id: str) -> list[dict[str, Any]]:
    """Return approved devices for one network only."""

    network_key = _normalize_network_id(network_id)

    with _lock:
        inventory = _read_inventory()

        devices = inventory["networks"].get(network_key, [])

        return [dict(device) for device in devices]


def trust_device(
    mac_address: str,
    network_id: str,
    device_name: str = "",
) -> dict[str, Any]:
    """Approve a device on a specific network."""

    mac = normalize_mac(mac_address)
    network_key = _normalize_network_id(network_id)

    alias = device_name.strip()

    if len(alias) > 80:
        raise ValueError("Device name must be 80 characters or less.")

    with _lock:
        inventory = _read_inventory()

        devices = inventory["networks"].setdefault(network_key, [])

        existing = next(
            (
                device for device in devices
                if device.get("mac_address") == mac
            ),
            None,
        )

        if existing:
            raise ValueError(
                "This device is already trusted on this network."
            )

        new_device = {
            "mac_address": mac,
            "device_name": alias or "Approved device",
            "network_id": network_key,
            "created_at": datetime.now(timezone.utc).isoformat(),
        }

        devices.append(new_device)

        _write_inventory(inventory)

        return new_device


def remove_trusted_device(
    mac_address: str,
    network_id: str,
) -> bool:
    """Remove approval only from the specified network."""

    mac = normalize_mac(mac_address)
    network_key = _normalize_network_id(network_id)

    with _lock:
        inventory = _read_inventory()

        devices = inventory["networks"].get(network_key, [])

        updated_devices = [
            device for device in devices
            if device.get("mac_address") != mac
        ]

        if len(updated_devices) == len(devices):
            return False

        inventory["networks"][network_key] = updated_devices

        _write_inventory(inventory)

        return True


def is_trusted(
    mac_address: str,
    network_id: str,
) -> bool:
    """Check approval within the current network only."""

    mac = normalize_mac(mac_address)
    network_key = _normalize_network_id(network_id)

    with _lock:
        inventory = _read_inventory()

        devices = inventory["networks"].get(network_key, [])

        return any(
            device.get("mac_address") == mac
            for device in devices
        )
