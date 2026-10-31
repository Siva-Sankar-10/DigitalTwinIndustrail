
from app.models.campus import (
    Campus,
    Department,
    NetworkDevice,
    NetworkConnection,
)


def generate_campus() -> Campus:
    campus = Campus(name="TwinGuard Demo Campus")

    department_configs = [
        {
            "id": "CSE",
            "name": "Computer Science",
            "building": "Block A",
            "floors": 3,
            "switches": 2,
            "computers": 10,
        },
        {
            "id": "ECE",
            "name": "Electronics",
            "building": "Block B",
            "floors": 2,
            "switches": 2,
            "computers": 8,
        },
        {
            "id": "IT",
            "name": "Information Technology",
            "building": "Block C",
            "floors": 2,
            "switches": 2,
            "computers": 8,
        },
        {
            "id": "ADMIN",
            "name": "Administration",
            "building": "Block D",
            "floors": 2,
            "switches": 1,
            "computers": 5,
        },
    ]

    for config in department_configs:
        dept_id = config["id"]

        campus.departments.append(
            Department(
                department_id=dept_id,
                name=config["name"],
                building=config["building"],
                floor_count=config["floors"],
            )
        )

        router_id = f"{dept_id}-R1"

        campus.devices.append(
            NetworkDevice(
                device_id=router_id,
                name=f"{dept_id} Router",
                device_type="router",
                department_id=dept_id,
                ip_address=f"10.{len(campus.departments)}.0.1",
                mac_address=f"02:00:{len(campus.departments):02X}:00:00:01",
            )
        )

        for switch_number in range(1, config["switches"] + 1):
            switch_id = f"{dept_id}-SW{switch_number}"

            campus.devices.append(
                NetworkDevice(
                    device_id=switch_id,
                    name=f"{dept_id} Switch {switch_number}",
                    device_type="switch",
                    department_id=dept_id,
                    ip_address=(
                        f"10.{len(campus.departments)}.0."
                        f"{switch_number + 1}"
                    ),
                    mac_address=(
                        f"02:00:{len(campus.departments):02X}:"
                        f"00:00:{switch_number + 1:02X}"
                    ),
                )
            )

            campus.connections.append(
                NetworkConnection(
                    connection_id=f"{dept_id}-LINK-R{switch_number}",
                    source_device_id=router_id,
                    target_device_id=switch_id,
                )
            )

            for pc_number in range(1, config["computers"] + 1):
                pc_id = f"{dept_id}-PC{switch_number}-{pc_number}"

                campus.devices.append(
                    NetworkDevice(
                        device_id=pc_id,
                        name=f"{dept_id} Computer {switch_number}-{pc_number}",
                        device_type="computer",
                        department_id=dept_id,
                        ip_address=(
                            f"10.{len(campus.departments)}."
                            f"{switch_number}.{pc_number + 10}"
                        ),
                        mac_address=(
                            f"02:{len(campus.departments):02X}:"
                            f"{switch_number:02X}:"
                            f"{pc_number:02X}:00:01"
                        ),
                    )
                )

                campus.connections.append(
                    NetworkConnection(
                        connection_id=f"{dept_id}-LINK-{pc_id}",
                        source_device_id=switch_id,
                        target_device_id=pc_id,
                    )
                )

    return campus
