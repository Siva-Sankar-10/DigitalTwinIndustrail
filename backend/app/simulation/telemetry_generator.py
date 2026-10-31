
import random
from datetime import datetime, timezone

from app.models.campus import Campus


def generate_telemetry(campus: Campus) -> list[dict]:
    """
    Generate simulated network telemetry for every campus device.

    Each call produces a fresh snapshot.
    These values are for prototype demonstration only.
    """

    telemetry_records = []

    for device in campus.devices:
        device_type = device.device_type.lower()

        # Different device types have different demonstration ranges.
        if device_type == "router":
            rx_range = (80.0, 450.0)
            tx_range = (70.0, 400.0)
            latency_range = (1.0, 8.0)

        elif device_type == "switch":
            rx_range = (10.0, 180.0)
            tx_range = (10.0, 160.0)
            latency_range = (1.0, 5.0)

        else:
            rx_range = (0.5, 35.0)
            tx_range = (0.5, 25.0)
            latency_range = (2.0, 25.0)

        record = {
            "device_id": device.device_id,
            "device_name": device.name,
            "department_id": device.department_id,
            "device_type": device.device_type,
            "ip_address": device.ip_address,
    "mac_address": device.mac_address,
            "status": device.status,

            "bandwidth_rx_mbps": round(
                random.uniform(*rx_range), 2
            ),

            "bandwidth_tx_mbps": round(
                random.uniform(*tx_range), 2
            ),

            "latency_ms": round(
                random.uniform(*latency_range), 2
            ),

            "packet_loss_percent": round(
                random.uniform(0.0, 0.5), 2
            ),

            "source": "SIMULATED",
            "sampled_at": datetime.now(
                timezone.utc
            ).isoformat(),
        }

        telemetry_records.append(record)

    return telemetry_records
