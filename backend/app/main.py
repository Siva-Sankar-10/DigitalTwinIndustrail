import subprocess
from contextlib import asynccontextmanager
from dataclasses import asdict
from typing import Optional
from fastapi import FastAPI, HTTPException, Query
from pydantic import BaseModel, Field

from app.analysis.fault_detector import analyze_telemetry
from app.simulation.telemetry_generator import generate_telemetry
from app.simulation.campus_generator import generate_campus

from app.discovery.wifi_discovery import discover_wifi_devices
from app.network_traffic import network_traffic_collector
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
    """Start the Wi-Fi monitor on startup and stop it on shutdown."""

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
        "network-specific device history, trusted-device management, "
        "and rule-based fault detection."
    ),
    version="1.5.0",
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
        "version": "1.5.0",
        "features": [
            "Simulated campus topology",
            "Real Windows network-interface traffic monitoring",
            "Simulated network telemetry",
            "Rule-based network fault detection",
            "Real Wi-Fi device discovery",
            "Automatic network identification",
            "Automatic Wi-Fi network monitoring",
            "Network-specific device history",
            "Network inventory",
            "Network-specific trusted-device inventory",
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
    """Return the current automatic Wi-Fi monitor status."""
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
    """Return simulated telemetry, optionally filtered by department."""

    campus = generate_campus()
    telemetry_records = generate_telemetry(campus)

    if department_id:
        department_id = department_id.strip()
        telemetry_records = [
            record
            for record in telemetry_records
            if record["department_id"].lower() == department_id.lower()
        ]

    return {
        "data_source": "SIMULATED",
        "department_id": department_id,
        "total_records": len(telemetry_records),
        "telemetry": telemetry_records,
    }
# ==========================================
# REAL-TIME NETWORK TRAFFIC
# ==========================================

@app.get("/api/telemetry/network")
def get_network_traffic(
    interface_alias: str = Query(
        default="Wi-Fi",
        min_length=1,
        max_length=64,
    ),
):
    """
    Return real Windows network-interface traffic counters.

    Measures traffic received and transmitted by the selected
    laptop network interface. It does not measure all devices
    connected to the Wi-Fi router.
    """

    try:
        return network_traffic_collector.collect(
            interface_alias=interface_alias,
        )

    except ValueError as error:
        raise HTTPException(
            status_code=400,
            detail=str(error),
        ) from error

    except (RuntimeError, OSError) as error:
        raise HTTPException(
            status_code=503,
            detail=str(error),
        ) from error

# ==========================================
# NETWORK FAULT DETECTION
# ==========================================

@app.get("/api/analysis/faults")
def get_fault_analysis(
    department_id: Optional[str] = Query(
        default=None,
        min_length=1,
        max_length=32,
    ),
):
    """
    Run rule-based analysis against the current generated telemetry.

    This endpoint reports threshold-based alerts. It does not perform
    machine-learning prediction or inspect the real Wi-Fi scan.
    """

    try:
        telemetry_data = get_telemetry(department_id=department_id)
        return analyze_telemetry(telemetry_data)
    except ValueError as error:
        raise HTTPException(
            status_code=400,
            detail=str(error),
        ) from error


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
    """Discover devices visible through an authorized local Wi-Fi interface."""

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
            detail="Unable to access Windows network discovery tools.",
        ) from error


# ==========================================
# NETWORK INVENTORY
# ==========================================

@app.get("/api/networks")
def list_networks():
    """Return all networks previously observed by discovery."""

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

def get_current_trusted_network_id() -> str:
    """Get the currently connected network ID from the monitor."""

    monitor = get_network_monitor_status()

    if not monitor.get("enabled") or not monitor.get("connected"):
        raise HTTPException(
            status_code=503,
            detail="Network monitor is not connected.",
        )

    network_id = monitor.get("network_id")
    if not network_id:
        raise HTTPException(
            status_code=503,
            detail="Current network identity is unavailable.",
        )

    return str(network_id)


@app.get("/api/trusted-devices")
def list_trusted_devices():
    """Return trusted devices for the current network."""

    try:
        network_id = get_current_trusted_network_id()
        devices = get_trusted_devices(network_id)
        return {
            "success": True,
            "network_id": network_id,
            "total": len(devices),
            "devices": devices,
        }
    except HTTPException:
        raise
    except RuntimeError as error:
        raise HTTPException(
            status_code=500,
            detail=str(error),
        ) from error


@app.post("/api/trusted-devices")
def add_trusted_device(
    request: TrustDeviceRequest,
):
    """Approve a device on the current network."""

    try:
        network_id = get_current_trusted_network_id()
        device = trust_device(
            mac_address=request.mac_address,
            network_id=network_id,
            device_name=request.device_name,
        )
        return {
            "success": True,
            "message": "Device approved successfully.",
            "network_id": network_id,
            "device": device,
        }
    except HTTPException:
        raise
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
    """Remove approval from the current network only."""

    try:
        network_id = get_current_trusted_network_id()
        removed = remove_trusted_device(
            mac_address=mac_address,
            network_id=network_id,
        )

        if not removed:
            raise HTTPException(
                status_code=404,
                detail="Trusted device not found on this network.",
            )

        return {
            "success": True,
            "message": "Device removed from this network's trusted inventory.",
            "network_id": network_id,
        }
    except HTTPException:
        raise
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
    limit: int = Query(default=100, ge=1, le=500),
    network_id: Optional[str] = Query(
        default=None,
        min_length=1,
        max_length=100,
    ),
):
    """Return legacy global or selected-network device history."""

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
    limit: int = Query(default=100, ge=1, le=500),
    network_id: Optional[str] = Query(
        default=None,
        min_length=1,
        max_length=100,
    ),
):
    """Return legacy global or selected-network discovery events."""

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
