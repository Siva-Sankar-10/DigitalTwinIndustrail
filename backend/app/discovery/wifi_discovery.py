
import ipaddress
import json
import re
import subprocess

from concurrent.futures import ThreadPoolExecutor
from typing import Any

from app.discovery.device_history import (
    record_discovery_scan,
    get_device_history,
)

from app.discovery.trusted_inventory import is_trusted


def _run_powershell(script: str) -> Any:
    """Execute a read-only PowerShell command and parse JSON output."""

    result = subprocess.run(
        [
            "powershell.exe",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            script,
        ],
        capture_output=True,
        text=True,
        timeout=15,
    )

    if result.returncode != 0:
        raise RuntimeError(
            result.stderr.strip() or "PowerShell command failed."
        )

    if not result.stdout.strip():
        raise RuntimeError("No output received from Windows.")

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise RuntimeError(
            "Invalid JSON received from PowerShell."
        ) from error


def _get_wifi_configuration(
    interface_alias: str,
) -> dict[str, Any]:
    """Read the selected Wi-Fi adapter configuration."""

    safe_alias = interface_alias.replace("'", "''")

    script = f"""
    $adapter = Get-NetAdapter -Name '{safe_alias}' -ErrorAction Stop
    $config = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex
    $ip = $config.IPv4Address | Select-Object -First 1
    $gateway = $config.IPv4DefaultGateway | Select-Object -First 1

    [PSCustomObject]@{{
        interface_alias = $adapter.Name
        interface_index = $adapter.ifIndex
        adapter_status = $adapter.Status.ToString()
        ip_address = $ip.IPAddress
        prefix_length = $ip.PrefixLength
        gateway = if ($gateway) {{ $gateway.NextHop }} else {{ $null }}
    }} | ConvertTo-Json -Compress
    """

    config = _run_powershell(script)

    if not isinstance(config, dict):
        raise RuntimeError("Invalid Wi-Fi configuration.")

    if not config.get("ip_address"):
        raise RuntimeError(
            "The Wi-Fi adapter does not have an IPv4 address."
        )

    if config.get("adapter_status") != "Up":
        raise RuntimeError("The Wi-Fi adapter is not connected.")

    return config


def _ping_host(
    address: str,
    source_ip: str,
    timeout_ms: int,
) -> bool:
    """Send one ICMP echo request to a local network address."""

    try:
        result = subprocess.run(
            [
                "ping.exe",
                "-n", "1",
                "-w", str(timeout_ms),
                "-S", source_ip,
                address,
            ],
            capture_output=True,
            text=True,
            timeout=(timeout_ms / 1000) + 2,
        )

        return result.returncode == 0

    except subprocess.TimeoutExpired:
        return False


def _normalize_mac(value: str) -> str | None:
    """Normalize and validate a unicast MAC address."""

    if not value:
        return None

    cleaned = re.sub(r"[^0-9A-Fa-f]", "", value)

    if len(cleaned) != 12:
        return None

    if cleaned == "000000000000":
        return None

    first_octet = int(cleaned[:2], 16)

    # Ignore multicast and broadcast MAC addresses.
    if first_octet & 1:
        return None

    return ":".join(
        cleaned[i:i + 2].upper()
        for i in range(0, 12, 2)
    )


def _format_neighbor_state(state: Any) -> str:
    """Convert Windows neighbor-state numbers to readable names."""

    state_names = {
        0: "Unreachable",
        1: "Incomplete",
        2: "Probe",
        3: "Delay",
        4: "Stale",
        5: "Reachable",
        6: "Permanent",
    }

    try:
        numeric_state = int(state)

        return state_names.get(
            numeric_state,
            str(state),
        )

    except (ValueError, TypeError):
        return str(state)


def _get_neighbors(
    interface_index: int,
) -> list[dict[str, Any]]:
    """Read the Windows IPv4 neighbor table."""

    script = f"""
    $rows = @(
        Get-NetNeighbor `
            -InterfaceIndex {interface_index} `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
        Select-Object IPAddress, LinkLayerAddress, State
    )

    ConvertTo-Json -InputObject $rows -Compress -Depth 4
    """

    result = _run_powershell(script)

    if isinstance(result, dict):
        return [result]

    if isinstance(result, list):
        return result

    return []


def discover_wifi_devices(
    interface_alias: str = "Wi-Fi",
    timeout_ms: int = 400,
    max_workers: int = 8,
) -> dict[str, Any]:
    """
    Discover devices visible through an authorized Wi-Fi interface.

    This is a read-only prototype.
    It does not modify, disconnect, or block network devices.
    """

    # --------------------------------------
    # 1. GET WI-FI CONFIGURATION
    # --------------------------------------

    config = _get_wifi_configuration(interface_alias)

    local_ip = config["ip_address"]
    prefix = int(config["prefix_length"])
    gateway = config.get("gateway")

    interface = ipaddress.ip_interface(
        f"{local_ip}/{prefix}"
    )

    network = interface.network

    # Restrict the prototype to small IPv4 networks.
    if network.num_addresses > 512:
        raise ValueError(
            "Network is larger than the prototype discovery limit."
        )

    if max_workers < 1 or max_workers > 16:
        raise ValueError(
            "max_workers must be between 1 and 16."
        )

    if timeout_ms < 100 or timeout_ms > 1000:
        raise ValueError(
            "timeout_ms must be between 100 and 1000."
        )

    # --------------------------------------
    # 2. BUILD DISCOVERY TARGETS
    # --------------------------------------

    # Exclude the laptop itself.
    targets = [
        str(address)
        for address in network.hosts()
        if str(address) != local_ip
    ]

    # --------------------------------------
    # 3. PERFORM ICMP DISCOVERY
    # --------------------------------------

    with ThreadPoolExecutor(
        max_workers=max_workers
    ) as executor:

        responses = list(
            executor.map(
                lambda address: _ping_host(
                    address,
                    local_ip,
                    timeout_ms,
                ),
                targets,
            )
        )

    responsive_ips = {
        address
        for address, responded in zip(targets, responses)
        if responded
    }

    # --------------------------------------
    # 4. READ WINDOWS NEIGHBOR TABLE
    # --------------------------------------

    neighbors = _get_neighbors(
        config["interface_index"]
    )

    devices = []

    for neighbor in neighbors:

        address = neighbor.get("IPAddress")
        raw_mac = neighbor.get("LinkLayerAddress")
        state = neighbor.get("State", "Unknown")

        if not address or not raw_mac:
            continue

        try:
            parsed_ip = ipaddress.ip_address(address)
        except ValueError:
            continue

        if parsed_ip not in network:
            continue

        if address == local_ip:
            continue

        mac = _normalize_mac(raw_mac)

        if mac is None:
            continue

        responded = address in responsive_ips
        is_gateway = address == gateway

        # Check local trusted-device inventory.
        trusted = is_trusted(mac)

        if is_gateway:
            classification = "gateway"
        elif trusted:
            classification = "trusted"
        else:
            classification = "unknown"

        device = {
            "ip_address": address,
            "mac_address": mac,
            "status": (
                "responsive"
                if responded
                else "neighbor_cache_only"
            ),
            "neighbor_state": _format_neighbor_state(state),
            "is_gateway": is_gateway,
            "is_trusted": trusted,
            "classification": classification,
            "source": "windows_wifi_neighbor_table",
        }

        devices.append(device)

    # --------------------------------------
    # 5. REMOVE DUPLICATES AND SORT
    # --------------------------------------

    unique_devices = {
        device["ip_address"]: device
        for device in devices
    }

    devices = sorted(
        unique_devices.values(),
        key=lambda item: ipaddress.ip_address(
            item["ip_address"]
        ),
    )

    # --------------------------------------
    # 6. SAVE DEVICE HISTORY
    # --------------------------------------

    history_result = record_discovery_scan(devices)

    # Retrieve persistent history.
    history_data = get_device_history(limit=500)

    history_by_mac = {
        item["mac_address"]: item
        for item in history_data["devices"]
    }

    # Attach history information to every discovered device.
    for device in devices:

        history = history_by_mac.get(
            device["mac_address"]
        )

        if history:
            device["first_seen"] = history.get("first_seen")
            device["last_seen"] = history.get("last_seen")
            device["sightings"] = history.get("sightings", 0)

    # --------------------------------------
    # 7. CALCULATE DISCOVERY SUMMARY
    # --------------------------------------

    responsive_count = sum(
        1
        for device in devices
        if device["status"] == "responsive"
    )

    trusted_count = sum(
        1
        for device in devices
        if device["classification"] == "trusted"
    )

    unknown_count = sum(
        1
        for device in devices
        if device["classification"] == "unknown"
    )

    # --------------------------------------
    # 8. RETURN COMPLETE RESPONSE
    # --------------------------------------

    return {
        "data_source": "REAL_WIFI_DISCOVERY",
        "simulation": False,

        "interface": {
            "name": config["interface_alias"],
            "index": config["interface_index"],
            "ip_address": local_ip,
            "prefix_length": prefix,
            "network": str(network),
            "gateway": gateway,
        },

        "summary": {
            "discovered_devices": len(devices),
            "responsive_devices": responsive_count,
            "trusted_devices": trusted_count,
            "unknown_devices": unknown_count,
            "newly_observed_devices": history_result["new_devices"],
            "gateway_detected": gateway is not None,
        },

        "history": history_result,

        "devices": devices,

        "limitations": [
            "Only devices visible to this laptop are returned.",
            "ICMP-disabled devices may still appear in the neighbor table.",
            "Wi-Fi client isolation and VLANs can hide devices.",
            "MAC randomization can cause previously approved devices "
            "to appear with a different MAC address.",
            "Unknown devices are not automatically considered intruders.",
            "This discovery service does not block or disconnect devices.",
        ],
    }
