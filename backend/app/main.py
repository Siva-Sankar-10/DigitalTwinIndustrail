
import subprocess
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


# ==========================================
# APPLICATION
# ==========================================

app = FastAPI(
    title="TwinGuard Edge API",
    description=(
        "Offline campus network digital twin, "
        "real Wi-Fi discovery and trusted-device management."
    ),
    version="1.2.0",
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
        "version": "1.2.0",
        "features": [
            "Simulated campus topology",
            "Simulated network telemetry",
            "Real Wi-Fi device discovery",
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

    Read-only operation.
    Does not block or disconnect devices.
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
            detail="Unable to access Windows network discovery tools.",
        ) from error


# ==========================================
# TRUSTED DEVICE INVENTORY
# ==========================================

@app.get("/api/trusted-devices")
def list_trusted_devices():
    """
    Return all locally approved devices.
    """

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
    """
    Approve a device and save it in the local inventory.
    """

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
    """
    Remove a device from the locally approved inventory.
    """

    try:
        removed = remove_trusted_device(mac_address)

        if not removed:
            raise HTTPException(
                status_code=404,
                detail="Trusted device not found.",
            )

        return {
            "success": True,
            "message": "Device removed from trusted inventory.",
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
