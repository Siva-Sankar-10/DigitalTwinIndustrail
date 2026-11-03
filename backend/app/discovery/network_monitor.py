
import ipaddress
import time

from datetime import datetime, timezone
from threading import Event, Lock, Thread
from typing import Any, Optional

from app.discovery.network_identity import (
    build_network_identity,
)

from app.discovery.wifi_discovery import (
    _get_wifi_configuration,
    _get_wifi_ssid,
    _get_neighbors,
    _normalize_mac,
    _format_neighbor_state,
    discover_wifi_devices,
)


_state_lock = Lock()
_stop_event = Event()

_monitor_thread: Optional[Thread] = None

_state: dict[str, Any] = {
    "enabled": False,
    "connected": False,
    "network": None,
    "network_id": None,
    "last_scan_at": None,
    "scan_status": "not_started",
    "last_error": None,
    "poll_interval_seconds": 10,
    "last_scanned_network_id": None,
    "last_scan_reason": None,
    "last_scan_summary": None,
    "observed_neighbor_count": 0,
    "new_neighbor_entries": [],

    # Persistent device-change event tracking.
    "device_change_sequence": 0,
    "last_device_change_at": None,
    "last_new_neighbor_entries": [],
}


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _detect_network(interface_alias: str) -> dict[str, Any]:
    """Identify the network currently connected to the laptop."""

    config = _get_wifi_configuration(interface_alias)

    gateway = config.get("gateway")

    if not gateway:
        raise RuntimeError(
            "Default gateway is unavailable."
        )

    local_ip = config["ip_address"]
    prefix = int(config["prefix_length"])

    subnet = str(
        ipaddress.ip_interface(
            f"{local_ip}/{prefix}"
        ).network
    )

    ssid = _get_wifi_ssid(
        config["interface_alias"]
    )

    return build_network_identity(
        ssid=ssid,
        gateway=gateway,
        subnet=subnet,
    )


def _read_neighbor_entries(
    interface_alias: str,
) -> dict[str, dict[str, Any]]:
    """
    Read currently visible IPv4 neighbor entries.

    Identify each entry using its IP and MAC address.
    These are newly observed entries, not guaranteed
    Wi-Fi association events.
    """

    config = _get_wifi_configuration(interface_alias)

    local_ip = config["ip_address"]

    network = ipaddress.ip_interface(
        f"{local_ip}/{int(config['prefix_length'])}"
    ).network

    neighbors = _get_neighbors(
        config["interface_index"]
    )

    entries: dict[str, dict[str, Any]] = {}

    for neighbor in neighbors:

        address = neighbor.get("IPAddress")
        raw_mac = neighbor.get("LinkLayerAddress")

        if not address or not raw_mac:
            continue

        try:
            parsed_ip = ipaddress.ip_address(str(address))
        except ValueError:
            continue

        if (
            not isinstance(parsed_ip, ipaddress.IPv4Address)
            or parsed_ip not in network
            or str(parsed_ip) == local_ip
        ):
            continue

        mac = _normalize_mac(raw_mac)

        if mac is None:
            continue

        key = f"{parsed_ip}|{mac}"

        entries[key] = {
            "ip_address": str(parsed_ip),
            "mac_address": mac,
            "neighbor_state": _format_neighbor_state(
                neighbor.get("State", "Unknown")
            ),
            "network": str(network),
        }

    return entries


def _perform_automatic_scan(
    interface_alias: str,
    network_id: str,
    reason: str = "network_change",
) -> None:
    """
    Run a Quick Scan after a network or device observation event.
    """

    with _state_lock:
        _state["scan_status"] = "scanning"
        _state["last_error"] = None

    print(
        f"[TwinGuard] Automatic Quick Scan started. "
        f"Reason: {reason}. Network: {network_id}",
        flush=True,
    )

    try:
        result = discover_wifi_devices(
            interface_alias=interface_alias,
            scan_mode="quick",
        )

        result_network_id = result["network"]["network_id"]

        if result_network_id != network_id:
            raise RuntimeError(
                "Network changed during discovery. "
                "The scan was not marked complete."
            )

        summary = result.get("summary", {})

        with _state_lock:
            _state["last_scan_at"] = _utc_now()
            _state["scan_status"] = "completed"
            _state["last_error"] = None
            _state["last_scanned_network_id"] = network_id
            _state["last_scan_reason"] = reason
            _state["last_scan_summary"] = summary

        print(
            "[TwinGuard] Automatic Quick Scan completed: "
            f"{summary.get('discovered_devices', 0)} devices",
            flush=True,
        )

    except Exception as error:

        with _state_lock:
            _state["scan_status"] = "failed"
            _state["last_error"] = str(error)

        print(
            f"[TwinGuard] Automatic scan failed: {error}",
            flush=True,
        )


def _monitor_loop(
    interface_alias: str,
    poll_interval: int,
) -> None:
    """Monitor Wi-Fi identity and newly observed neighbor entries."""

    last_attempt_network_id = None
    last_attempt_time = 0.0

    last_monitored_network_id = None
    known_neighbor_keys: set[str] = set()

    retry_interval = 60

    while not _stop_event.is_set():

        try:

            # --------------------------------------
            # 1. DETECT CURRENT NETWORK
            # --------------------------------------

            network = _detect_network(interface_alias)
            network_id = network["network_id"]

            with _state_lock:
                _state["connected"] = True
                _state["network"] = network
                _state["network_id"] = network_id
                _state["last_error"] = None

            now = time.monotonic()

            network_changed = (
                network_id != last_monitored_network_id
            )

            if network_changed:
                last_monitored_network_id = network_id
                known_neighbor_keys.clear()

                print(
                    f"[TwinGuard] Connected network detected: "
                    f"{network_id}",
                    flush=True,
                )

            # --------------------------------------
            # 2. DETECT NEW NEIGHBOR ENTRIES
            # --------------------------------------

            new_entries: list[dict[str, Any]] = []

            try:
                current_entries = _read_neighbor_entries(
                    interface_alias
                )

                current_keys = set(current_entries.keys())

                if network_changed:
                    # First snapshot becomes the baseline.
                    known_neighbor_keys = current_keys

                else:
                    new_keys = current_keys - known_neighbor_keys

                    new_entries = [
                        current_entries[key]
                        for key in sorted(new_keys)
                    ]

                    known_neighbor_keys.update(current_keys)

                with _state_lock:
                    _state["observed_neighbor_count"] = len(
                        current_entries
                    )

                    _state["new_neighbor_entries"] = new_entries

                    # Do not erase the last event on the next poll.
                    if new_entries:
                        _state["device_change_sequence"] += 1
                        _state["last_device_change_at"] = _utc_now()
                        _state["last_new_neighbor_entries"] = new_entries

                        print(
                            "[TwinGuard] New neighbor entries detected: "
                            f"{len(new_entries)}",
                            flush=True,
                        )

            except Exception as neighbor_error:
                # A neighbor-table read failure alone does not mean
                # that the Wi-Fi connection has disconnected.
                print(
                    "[TwinGuard] Neighbor-table check failed: "
                    f"{neighbor_error}",
                    flush=True,
                )

            # --------------------------------------
            # 3. DECIDE WHETHER TO SCAN
            # --------------------------------------

            with _state_lock:
                last_scanned_network_id = _state.get(
                    "last_scanned_network_id"
                )
                current_scan_status = _state.get(
                    "scan_status"
                )

            if network_id != last_attempt_network_id:
                last_attempt_network_id = None

            network_scan_due = (
                network_id != last_scanned_network_id
                and (
                    network_id != last_attempt_network_id
                    or now - last_attempt_time >= retry_interval
                )
            )

            new_device_detected = bool(new_entries)

            retry_due = (
                network_id == last_attempt_network_id
                and current_scan_status == "failed"
                and now - last_attempt_time >= retry_interval
            )

            should_scan = (
                network_scan_due
                or new_device_detected
                or retry_due
            )

            # --------------------------------------
            # 4. AUTOMATIC QUICK SCAN
            # --------------------------------------

            if should_scan:

                if network_scan_due:
                    reason = "network_change"
                elif new_device_detected:
                    reason = "new_neighbor_entry"
                else:
                    reason = "retry"

                last_attempt_network_id = network_id
                last_attempt_time = now

                _perform_automatic_scan(
                    interface_alias,
                    network_id,
                    reason=reason,
                )

        except Exception as error:

            with _state_lock:
                _state["connected"] = False
                _state["network"] = None
                _state["network_id"] = None
                _state["scan_status"] = "waiting_for_network"
                _state["last_error"] = str(error)
                _state["last_scanned_network_id"] = None
                _state["observed_neighbor_count"] = 0
                _state["new_neighbor_entries"] = []

            last_attempt_network_id = None
            last_attempt_time = 0.0

            last_monitored_network_id = None
            known_neighbor_keys.clear()

            print(
                f"[TwinGuard] Waiting for Wi-Fi: {error}",
                flush=True,
            )

        _stop_event.wait(poll_interval)

    with _state_lock:
        _state["enabled"] = False

    print(
        "[TwinGuard] Network monitor stopped.",
        flush=True,
    )


def start_network_monitor(
    interface_alias: str = "Wi-Fi",
    poll_interval: int = 10,
) -> dict[str, Any]:
    """Start the background Wi-Fi network monitor."""

    global _monitor_thread

    if poll_interval < 5 or poll_interval > 300:
        raise ValueError(
            "Poll interval must be between 5 and 300 seconds."
        )

    with _state_lock:

        if (
            _monitor_thread is not None
            and _monitor_thread.is_alive()
        ):
            return dict(_state)

        _stop_event.clear()

        _state.update({
            "enabled": True,
            "connected": False,
            "network": None,
            "network_id": None,
            "last_scan_at": None,
            "scan_status": "starting",
            "last_error": None,
            "last_scanned_network_id": None,
            "last_scan_reason": None,
            "last_scan_summary": None,
            "observed_neighbor_count": 0,
            "new_neighbor_entries": [],
            "poll_interval_seconds": poll_interval,
        })

        # Keep device_change_sequence and last event details.
        # They must remain available to clients that poll the API.
        _state.setdefault("device_change_sequence", 0)
        _state.setdefault("last_device_change_at", None)
        _state.setdefault("last_new_neighbor_entries", [])

        _monitor_thread = Thread(
            target=_monitor_loop,
            args=(interface_alias, poll_interval),
            name="TwinGuardNetworkMonitor",
            daemon=True,
        )

        _monitor_thread.start()

        return dict(_state)


def stop_network_monitor() -> None:
    """Stop the background monitor."""

    global _monitor_thread

    _stop_event.set()

    thread = _monitor_thread

    if thread is not None and thread.is_alive():
        thread.join(timeout=5)

    _monitor_thread = None

    with _state_lock:
        _state["enabled"] = False


def get_network_monitor_status() -> dict[str, Any]:
    """Return the current monitor status."""

    with _state_lock:
        return dict(_state)
