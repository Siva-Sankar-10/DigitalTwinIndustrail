import json
import os
import tempfile

from datetime import datetime, timezone
from pathlib import Path
from threading import Lock
from typing import Any


DATA_DIR = Path(__file__).resolve().parents[2] / "data"
DATA_FILE = DATA_DIR / "network_device_history.json"

_history_lock = Lock()


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _load_data() -> dict[str, Any]:
    if not DATA_FILE.exists():
        return {
            "schema_version": 1,
            "networks": {},
            "events": [],
        }

    try:
        with DATA_FILE.open("r", encoding="utf-8") as file:
            data = json.load(file)

        if not isinstance(data, dict):
            raise ValueError("Invalid history format.")

        data.setdefault("networks", {})
        data.setdefault("events", [])

        return data

    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise RuntimeError(
            f"Unable to read network history: {error}"
        ) from error


def _save_data(data: dict[str, Any]) -> None:
    DATA_DIR.mkdir(parents=True, exist_ok=True)

    temp_path = None

    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            suffix=".tmp",
            prefix="network_history_",
            dir=DATA_DIR,
            delete=False,
        ) as file:
            json.dump(data, file, indent=2)
            file.flush()
            os.fsync(file.fileno())
            temp_path = file.name

        os.replace(temp_path, DATA_FILE)

    finally:
        if temp_path and os.path.exists(temp_path):
            os.remove(temp_path)


def record_network_scan(
    network: dict[str, Any],
    discovered_devices: list[dict[str, Any]],
) -> dict[str, Any]:
    """
    Record discovered devices separately for each network.

    A device on another network gets a separate history record,
    even when its MAC address is the same.
    """

    network_id = str(network.get("network_id", "")).strip()

    if not network_id:
        raise ValueError("Network ID is required.")

    now = _utc_now()

    new_count = 0
    updated_count = 0
    observed_count = 0

    with _history_lock:
        data = _load_data()

        networks = data["networks"]

        network_record = networks.setdefault(
            network_id,
            {
                "network_id": network_id,
                "network_name": network.get("network_name"),
                "ssid": network.get("ssid"),
                "gateway": network.get("gateway"),
                "subnet": network.get("subnet"),
                "first_seen": now,
                "last_seen": now,
                "scan_count": 0,
                "devices": {},
            },
        )

        # Refresh network metadata.
        network_record["network_name"] = network.get(
            "network_name"
        )
        network_record["ssid"] = network.get("ssid")
        network_record["gateway"] = network.get("gateway")
        network_record["subnet"] = network.get("subnet")

        network_record["last_seen"] = now
        network_record["scan_count"] += 1

        device_records = network_record["devices"]

        for device in discovered_devices:

            mac = str(
                device.get("mac_address", "")
            ).strip().upper()

            if not mac:
                continue

            observed_count += 1

            ip_address = device.get("ip_address")

            existing = device_records.get(mac)

            if existing is None:

                device_records[mac] = {
                    "mac_address": mac,
                    "first_seen": now,
                    "last_seen": now,
                    "last_ip_address": ip_address,
                    "sightings": 1,
                    "last_status": device.get("status"),
                    "last_classification": device.get(
                        "classification"
                    ),
                    "last_responsive_at": (
                        now
                        if device.get("status") == "responsive"
                        else None
                    ),
                }

                new_count += 1

                event_type = (
                    "gateway_added_to_baseline"
                    if device.get("is_gateway")
                    else "new_device_observed"
                )

                data["events"].append({
                    "event_type": event_type,
                    "severity": (
                        "info"
                        if device.get("is_gateway")
                        else "review"
                    ),
                    "network_id": network_id,
                    "network_name": network_record.get(
                        "network_name"
                    ),
                    "mac_address": mac,
                    "ip_address": ip_address,
                    "timestamp": now,
                    "message": (
                        "Network gateway added to baseline."
                        if device.get("is_gateway")
                        else "A new device was observed on this network."
                    ),
                })

            else:
                previous_ip = existing.get("last_ip_address")

                existing["last_seen"] = now
                existing["last_ip_address"] = ip_address
                existing["sightings"] = (
                    existing.get("sightings", 0) + 1
                )
                existing["last_status"] = device.get("status")
                existing["last_classification"] = device.get(
                    "classification"
                )

                if device.get("status") == "responsive":
                    existing["last_responsive_at"] = now

                updated_count += 1

                if previous_ip and ip_address != previous_ip:
                    data["events"].append({
                        "event_type": "ip_address_changed",
                        "severity": "info",
                        "network_id": network_id,
                        "network_name": network_record.get(
                            "network_name"
                        ),
                        "mac_address": mac,
                        "previous_ip_address": previous_ip,
                        "ip_address": ip_address,
                        "timestamp": now,
                        "message": (
                            "Device IP address changed on this network."
                        ),
                    })

        # Keep only the latest 1000 events.
        data["events"] = data["events"][-1000:]

        _save_data(data)

        return {
            "network_id": network_id,
            "network_name": network_record.get("network_name"),
            "scan_time": now,
            "observed_devices": observed_count,
            "new_devices": new_count,
            "updated_devices": updated_count,
            "scan_count": network_record["scan_count"],
        }


def get_network_history(
    network_id: str,
) -> dict[str, Any]:
    """Retrieve device history for one specific network."""

    with _history_lock:
        data = _load_data()

        network_record = data["networks"].get(network_id)

        if network_record is None:
            return {
                "network": None,
                "devices": [],
                "events": [],
            }

        devices = list(
            network_record.get("devices", {}).values()
        )

        events = [
            event
            for event in data["events"]
            if event.get("network_id") == network_id
        ]

        return {
            "network": {
                key: value
                for key, value in network_record.items()
                if key != "devices"
            },
            "devices": devices,
            "events": events,
        }


def get_all_networks() -> list[dict[str, Any]]:
    """Return the known network inventory."""

    with _history_lock:
        data = _load_data()

        return [
            {
                key: value
                for key, value in network.items()
                if key != "devices"
            }
            for network in data["networks"].values()
        ]