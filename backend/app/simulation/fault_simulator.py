from collections import deque
from dataclasses import asdict
from typing import Any

from app.simulation.campus_generator import generate_campus


def simulate_fault(
    department_id: str,
    failed_device_id: str,
) -> dict[str, Any]:

    campus = generate_campus()

    department_id = department_id.strip().upper()
    failed_device_id = failed_device_id.strip()

    # Find the requested device.
    device_map = {
        device.device_id: device
        for device in campus.devices
    }

    failed_device = device_map.get(failed_device_id)

    if failed_device is None:
        raise ValueError("Device not found.")

    if failed_device.department_id != department_id:
        raise ValueError("Device does not belong to this department.")

    # Build a directed network graph.
    adjacency = {}

    for connection in campus.connections:
        if connection.status.lower() != "active":
            continue

        adjacency.setdefault(
            connection.source_device_id, []
        ).append(connection.target_device_id)

    # Find downstream devices affected by the failure.
    visited = {failed_device_id}
    queue = deque(adjacency.get(failed_device_id, []))
    affected_devices = []

    while queue:
        current_id = queue.popleft()

        if current_id in visited:
            continue

        visited.add(current_id)

        current_device = device_map.get(current_id)

        if current_device is None:
            continue

        affected_devices.append(current_device)

        for child_id in adjacency.get(current_id, []):
            if child_id not in visited:
                queue.append(child_id)

    return {
        "simulation": True,
        "data_source": "simulated",
        "department_id": department_id,
        "failed_device": asdict(failed_device),
        "affected_count": len(affected_devices),
        "affected_devices": [
            {
                **asdict(device),
                "simulated_status": "unreachable",
            }
            for device in affected_devices
        ],
        "note": (
            "This is a simulated downstream impact estimate. "
            "Original campus devices and connections were not modified."
        ),
    }