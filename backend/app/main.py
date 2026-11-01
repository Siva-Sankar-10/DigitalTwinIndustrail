
import subprocess

from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Optional

from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

from app.simulation.telemetry_generator import generate_telemetry
from app.simulation.campus_generator import generate_campus

from app.discovery.wifi_discovery import discover_wifi_devices

from app.discovery.trusted_inventory import (
    get_trusted_devices,
    trust_device,
    remove_trusted_device,
)

from app.discovery.device_history import (
    get_device_history,
    get_device_events,
)

from app.discovery.network_device_history import (
    get_all_networks,
    get_network_history,
)

from app.discovery.network_monitor import (
    start_network_monitor,
    stop_network_monitor,
    get_network_monitor_status,
)


# ==========================================
# AUTOMATIC NETWORK MONITOR LIFESPAN
# ==========================================

@asynccontextmanager
async def lifespan(app: FastAPI):
    """
    Start the Wi-Fi network monitor when FastAPI starts.

    Stop the background monitor when FastAPI shuts down.
    """

    print(
        "[TwinGuard] Starting automatic network monitor...",
        flush=True,
    )

    start_network_monitor(
        interface_alias="Wi-Fi",
        poll_interval=10,
    )

    try:
        yield

    finally:
        print(
            "[TwinGuard] Stopping automatic network monitor...",
            flush=True,
        )

        stop_network_monitor()


# ==========================================
# APPLICATION
# ==========================================

app = FastAPI(
    title="TwinGuard Edge API",
    description=(
        "Offline campus network digital twin, "
        "real Wi-Fi discovery, automatic network identification, "
        "network-specific device history and "
        "trusted-device management."
    ),
    version="1.4.0",
    lifespan=lifespan,
)


# ==========================================
# REQUEST MODELS
# ==========================================

class TrustDeviceRequest(BaseModel):

    mac_address: str = Field(
        min_length=12,
        max_length=17,
    )

    device_name: str = Field(
        default="",
        max_length=80,
    )


# ==========================================
# HOME AND HEALTH
# ==========================================

@app.get("/")
def home():
    return {
        "application": "TwinGuard Edge",
        "status": "running",
        "mode": "HYBRID",
        "version": "1.4.0",
        "features": [
            "Simulated campus topology",
            "Simulated network telemetry",
            "Real Wi-Fi device discovery",
            "Automatic network identification",
            "Automatic Wi-Fi network monitoring",
            "Network-specific device history",
            "Network inventory",
            "Trusted-device inventory",
        ],
    }


@app.get("/health")
def health():
    return {
        "status": "healthy",
        "data_source": "LOCAL_BACKEND",
    }


# ==========================================
# AUTOMATIC NETWORK MONITOR STATUS
# ==========================================

@app.get("/api/network-monitor/status")
def network_monitor_status():
    """
    Return the current automatic Wi-Fi monitor status.

    Includes:
        - Monitor enabled state
        - Wi-Fi connection state
        - Current network identity
        - Last automatic scan time
        - Scan status
        - Last error
    """

    return get_network_monitor_status()


# ==========================================
# CAMPUS DIGITAL TWIN
# ==========================================

@app.get("/api/campus")
def get_campus():

    campus = generate_campus()

    return {
        "data_source": "SIMULATED",

        "summary": {
            "departments": len(campus.departments),
            "devices": len(campus.devices),
            "connections": len(campus.connections),
        },

        "campus": asdict(campus),
    }


# ==========================================
# NETWORK TELEMETRY
# ==========================================

@app.get("/api/telemetry")
def get_telemetry(
    department_id: Optional[str] = None,
):
    """
    Return simulated telemetry for campus devices.

    Optionally filter by department ID.
    """

    campus = generate_campus()

    telemetry_records = generate_telemetry(campus)

    if department_id:
        department_id = department_id.strip()

        telemetry_records = [
            record
            for record in telemetry_records
            if record["department_id"].lower()
            == department_id.lower()
        ]

    return {
        "data_source": "SIMULATED",
        "department_id": department_id,
        "total_records": len(telemetry_records),
        "telemetry": telemetry_records,
    }


# ==========================================
# REAL WI-FI DEVICE DISCOVERY
# ==========================================

@app.get("/api/discovery/wifi")
def get_wifi_discovery(
    interface_alias: str = Query(
        default="Wi-Fi",
        min_length=1,
        max_length=64,
    ),
):
    """
    Discover devices visible through an authorized
    local Wi-Fi interface.

    This is a read-only operation.
    It does not block or disconnect devices.
    """

    try:
        return discover_wifi_devices(
            interface_alias=interface_alias,
        )

    except ValueError as error:
        raise HTTPException(
            status_code=400,
            detail=str(error),
        ) from error

    except subprocess.TimeoutExpired as error:
        raise HTTPException(
            status_code=504,
            detail="Wi-Fi discovery timed out.",
        ) from error

    except RuntimeError as error:
        raise HTTPException(
            status_code=503,
            detail=str(error),
        ) from error

    except OSError as error:
        raise HTTPException(
            status_code=503,
            detail=(
                "Unable to access Windows network "
                "discovery tools."
            ),
        ) from error


# ==========================================
# NETWORK INVENTORY
# ==========================================

@app.get("/api/networks")
def list_networks():
    """
    Return all networks previously observed
    by the network discovery service.
    """

    try:
        networks = get_all_networks()

        return {
            "success": True,
            "total_networks": len(networks),
            "networks": networks,
        }

    except RuntimeError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


# ==========================================
# TRUSTED DEVICE INVENTORY
# ==========================================

@app.get("/api/trusted-devices")
def list_trusted_devices():
    """Return all locally approved devices."""

    try:
        devices = get_trusted_devices()

        return {
            "success": True,
            "total": len(devices),
            "devices": devices,
        }

    except RuntimeError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


@app.post("/api/trusted-devices")
def add_trusted_device(
    request: TrustDeviceRequest,
):
    """Approve a device and save it in the local inventory."""

    try:
        device = trust_device(
            mac_address=request.mac_address,
            device_name=request.device_name,
        )

        return {
            "success": True,
            "message": "Device approved successfully.",
            "device": device,
        }

    except ValueError as error:
        raise HTTPException(
            status_code=400,
            detail=str(error),
        ) from error

    except RuntimeError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


@app.delete("/api/trusted-devices/{mac_address}")
def delete_trusted_device(
    mac_address: str,
):
    """Remove a device from the trusted inventory."""

    try:
        removed = remove_trusted_device(mac_address)

        if not removed:
            raise HTTPException(
                status_code=404,
                detail="Trusted device not found.",
            )

        return {
            "success": True,
            "message": (
                "Device removed from trusted inventory."
            ),
        }

    except ValueError as error:
        raise HTTPException(
            status_code=400,
            detail=str(error),
        ) from error

    except RuntimeError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


# ==========================================
# DEVICE HISTORY
# ==========================================

@app.get("/api/history/devices")
def list_device_history(
    limit: int = Query(
        default=100,
        ge=1,
        le=500,
    ),
    network_id: Optional[str] = Query(
        default=None,
        min_length=1,
        max_length=100,
    ),
):
    """
    Return device history.

    With network_id:
        Return network-specific device history.

    Without network_id:
        Preserve the legacy global history endpoint.
    """

    try:
        if network_id is None:
            return get_device_history(limit)

        network_id = network_id.strip()

        if not network_id:
            raise HTTPException(
                status_code=400,
                detail="Network ID cannot be empty.",
            )

        history = get_network_history(network_id)

        if history["network"] is None:
            raise HTTPException(
                status_code=404,
                detail="Network history not found.",
            )

        devices = sorted(
            history["devices"],
            key=lambda item: item.get("last_seen") or "",
            reverse=True,
        )

        return {
            "network": history["network"],
            "total_devices": len(history["devices"]),
            "devices": devices[:limit],
        }

    except HTTPException:
        raise

    except (ValueError, RuntimeError) as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


# ==========================================
# NETWORK DEVICE EVENTS
# ==========================================

@app.get("/api/history/events")
def list_device_events(
    limit: int = Query(
        default=100,
        ge=1,
        le=500,
    ),
    network_id: Optional[str] = Query(
        default=None,
        min_length=1,
        max_length=100,
    ),
):
    """
    Return discovery and device-change events.

    With network_id:
        Return events for the selected network.

    Without network_id:
        Preserve the legacy global event-history endpoint.
    """

    try:
        if network_id is None:
            return get_device_events(limit)

        network_id = network_id.strip()

        if not network_id:
            raise HTTPException(
                status_code=400,
                detail="Network ID cannot be empty.",
            )

        history = get_network_history(network_id)

        if history["network"] is None:
            raise HTTPException(
                status_code=404,
                detail="Network history not found.",
            )

        events = sorted(
            history["events"],
            key=lambda item: item.get("timestamp") or "",
            reverse=True,
        )

        return {
            "network": history["network"],
            "total_events": len(history["events"]),
            "events": events[:limit],
        }

    except HTTPException:
        raise

    except (ValueError, RuntimeError) as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error
