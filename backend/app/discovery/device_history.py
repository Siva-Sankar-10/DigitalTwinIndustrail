
import ipaddress
import json
import threading
import uuid

from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from app.discovery.trusted_inventory import normalize_mac


DATA_DIR = Path(__file__).resolve().parents[2] / "data"
HISTORY_FILE = DATA_DIR / "device_history.json"

_lock = threading.RLock()
MAX_EVENTS = 500


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _empty_store() -> dict[str, Any]:
    return {
        "devices": {},
        "events": [],
    }


def _read_store() -> dict[str, Any]:
    """Read persistent device history."""

    if not HISTORY_FILE.exists():
        return _empty_store()

    try:
        with HISTORY_FILE.open("r", encoding="utf-8") as file:
            data = json.load(file)

        if not isinstance(data, dict):
            raise ValueError("Invalid history format.")

        if not isinstance(data.get("devices"), dict):
            raise ValueError("Invalid device history records.")

        if not isinstance(data.get("events"), list):
            raise ValueError("Invalid event history.")

        return data

    except (json.JSONDecodeError, OSError, ValueError) as error:
        raise RuntimeError(
            "Could not read device history."
        ) from error


def _write_store(data: dict[str, Any]) -> None:
    """Save history atomically."""

    DATA_DIR.mkdir(parents=True, exist_ok=True)

    temporary_file = HISTORY_FILE.with_suffix(".tmp")

    try:
        with temporary_file.open("w", encoding="utf-8") as file:
            json.dump(data, file, indent=4)

        temporary_file.replace(HISTORY_FILE)

    except OSError as error:
        temporary_file.unlink(missing_ok=True)

        raise RuntimeError(
            "Could not save device history."
        ) from error


def _add_event(
    store: dict[str, Any],
    event_type: str,
    mac_address: str,
    ip_address: str,
    message: str,
    **details: Any,
) -> None:
    """Add a device history event."""

    event = {
        "event_id": str(uuid.uuid4()),
        "event_type": event_type,
        "mac_address": mac_address,
        "ip_address": ip_address,
        "message": message,
        "occurred_at": _now(),
        **details,
    }

    store["events"].append(event)

    # Keep the most recent 500 events.
    store["events"] = store["events"][-MAX_EVENTS:]


def _correct_existing_gateway_events(
    store: dict[str, Any],
    mac_address: str,
) -> None:
    """
    Correct older gateway events that were incorrectly
    recorded as unknown-device review events.
    """

    for event in store["events"]:
        if (
            event.get("mac_address") == mac_address
            and event.get("event_type") == "new_device_observed"
            and event.get("classification") == "gateway"
        ):
            event["event_type"] = "gateway_added_to_baseline"
            event["message"] = (
                "Network gateway recorded in device history."
            )
            event["severity"] = "info"


def record_discovery_scan(
    discovered_devices: list[dict[str, Any]],
) -> dict[str, Any]:
    """
    Update persistent history using discovered devices.

    A newly observed MAC address means that it was not previously
    present in local history. It does not prove intrusion.
    """

    with _lock:
        store = _read_store()

        records = store["devices"]
        observed_macs = set()

        new_count = 0
        updated_count = 0

        scan_time = _now()

        for device in discovered_devices:
            raw_mac = device.get("mac_address")
            raw_ip = device.get("ip_address")

            if not raw_mac or not raw_ip:
                continue

            try:
                mac = normalize_mac(str(raw_mac))
                ip_address = str(
                    ipaddress.ip_address(raw_ip)
                )
            except ValueError:
                continue

            # Avoid duplicate entries in the same scan.
            if mac in observed_macs:
                continue

            observed_macs.add(mac)

            status = str(
                device.get("status", "unknown")
            )

            classification = str(
                device.get("classification", "unknown")
            )

            existing = records.get(mac)

            # --------------------------------------
            # NEWLY OBSERVED DEVICE
            # --------------------------------------

            if existing is None:

                records[mac] = {
                    "mac_address": mac,
                    "first_seen": scan_time,
                    "last_seen": scan_time,
                    "last_ip_address": ip_address,
                    "last_status": status,
                    "last_classification": classification,
                    "sightings": 1,
                    "last_responsive_at": (
                        scan_time
                        if status == "responsive"
                        else None
                    ),
                }

                # Classify gateway separately.
                if classification == "gateway":
                    event_type = "gateway_added_to_baseline"

                    message = (
                        "Network gateway recorded in device history."
                    )

                    severity = "info"

                else:
                    event_type = "new_device_observed"

                    message = (
                        "A device not previously recorded in local "
                        "history was observed. Verify its ownership."
                    )

                    severity = "review"

                _add_event(
                    store,
                    event_type=event_type,
                    mac_address=mac,
                    ip_address=ip_address,
                    message=message,
                    severity=severity,
                    classification=classification,
                )

                new_count += 1

            # --------------------------------------
            # PREVIOUSLY OBSERVED DEVICE
            # --------------------------------------

            else:

                # Correct previously recorded gateway alerts.
                if classification == "gateway":
                    _correct_existing_gateway_events(
                        store,
                        mac,
                    )

                previous_ip = existing.get(
                    "last_ip_address"
                )

                existing["last_seen"] = scan_time

                existing["sightings"] = (
                    int(existing.get("sightings", 0)) + 1
                )

                existing["last_status"] = status
                existing["last_classification"] = classification

                if status == "responsive":
                    existing["last_responsive_at"] = scan_time

                # Detect IP address changes.
                if previous_ip != ip_address:

                    _add_event(
                        store,
                        event_type="ip_address_changed",
                        mac_address=mac,
                        ip_address=ip_address,
                        message=(
                            "The observed IP address changed. "
                            "This may be caused by DHCP."
                        ),
                        severity="info",
                        previous_ip_address=previous_ip,
                        current_ip_address=ip_address,
                    )

                existing["last_ip_address"] = ip_address

                updated_count += 1

        _write_store(store)

        return {
            "scan_time": scan_time,
            "observed_devices": len(observed_macs),
            "new_devices": new_count,
            "updated_devices": updated_count,
        }


def get_device_history(
    limit: int = 100,
) -> dict[str, Any]:
    """Return recently observed devices."""

    if limit < 1 or limit > 500:
        raise ValueError(
            "Limit must be between 1 and 500."
        )

    with _lock:
        store = _read_store()

        devices = list(
            store["devices"].values()
        )

        devices.sort(
            key=lambda item: item.get("last_seen", ""),
            reverse=True,
        )

        return {
            "total": len(devices),
            "devices": devices[:limit],
        }


def get_device_events(
    limit: int = 100,
) -> dict[str, Any]:
    """Return recent discovery and device-change events."""

    if limit < 1 or limit > 500:
        raise ValueError(
            "Limit must be between 1 and 500."
        )

    with _lock:
        store = _read_store()

        events = list(
            store["events"]
        )

        events.reverse()

        return {
            "total": len(store["events"]),
            "events": events[:limit],
        }
