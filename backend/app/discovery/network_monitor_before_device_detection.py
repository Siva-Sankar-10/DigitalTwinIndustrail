
import ipaddress
import time

from datetime import datetime, timezone
from threading import Event, Lock, Thread
from typing import Any, Optional

from app.discovery.network_identity import (
    build_network_identity,
)

from app.discovery.network_device_history import (
    get_all_networks,
)

from app.discovery.wifi_discovery import (
    _get_wifi_configuration,
    _get_wifi_ssid,
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


def _perform_automatic_scan(
    interface_alias: str,
    network_id: str,
) -> None:
    """Run a discovery scan when a new network is detected."""

    with _state_lock:
        _state["scan_status"] = "scanning"
        _state["last_error"] = None

    print(
        f"[TwinGuard] Network changed. Starting scan: {network_id}",
        flush=True,
    )

    try:
        result = discover_wifi_devices(
            interface_alias=interface_alias,
        )

        # Verify that the network did not change
        # while discovery was running.
        result_network_id = result["network"]["network_id"]

        if result_network_id != network_id:
            raise RuntimeError(
                "Network changed during discovery. "
                "The scan was not marked complete."
            )

        with _state_lock:
            _state["last_scan_at"] = _utc_now()
            _state["scan_status"] = "completed"
            _state["last_error"] = None
            _state["last_scanned_network_id"] = network_id

        print(
            "[TwinGuard] Automatic scan completed: "
            f"{result['summary']['discovered_devices']} devices",
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
    """Continuously monitor network identity."""

    last_attempt_network_id = None
    last_attempt_time = 0.0

    retry_interval = 60

    while not _stop_event.is_set():

        try:
            network = _detect_network(interface_alias)

            network_id = network["network_id"]

            with _state_lock:
                _state["connected"] = True
                _state["network"] = network
                _state["network_id"] = network_id
                _state["last_error"] = None

            now = time.monotonic()

            # Scan when the network changes or an earlier
            # attempt failed and its retry interval has passed.
            if network_id != last_attempt_network_id:
                last_attempt_network_id = None

            should_scan = (
                network_id != _state.get("last_scanned_network_id")
                and (
                    network_id != last_attempt_network_id
                    or now - last_attempt_time >= retry_interval
                )
            )

            if should_scan:
                last_attempt_network_id = network_id
                last_attempt_time = now

                _perform_automatic_scan(
                    interface_alias,
                    network_id,
                )

        except Exception as error:

            with _state_lock:
                _state["connected"] = False
                _state["network"] = None
                _state["network_id"] = None
                _state["scan_status"] = "waiting_for_network"
                _state["last_error"] = str(error)
                _state["last_scanned_network_id"] = None

            # Reconnecting to the same Wi-Fi should trigger
            # a fresh discovery scan.
            last_attempt_network_id = None
            last_attempt_time = 0.0

            print(
                f"[TwinGuard] Waiting for Wi-Fi: {error}",
                flush=True,
            )

        _stop_event.wait(poll_interval)

    with _state_lock:
        _state["enabled"] = False

    print("[TwinGuard] Network monitor stopped.", flush=True)


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

        if _monitor_thread is not None and _monitor_thread.is_alive():
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
            "poll_interval_seconds": poll_interval,
        })

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
