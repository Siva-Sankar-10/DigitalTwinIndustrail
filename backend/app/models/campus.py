
from dataclasses import dataclass, field
from typing import List, Optional


@dataclass
class Department:
    department_id: str
    name: str
    building: str
    floor_count: int


@dataclass
class NetworkDevice:
    device_id: str
    name: str
    device_type: str
    department_id: str
    ip_address: str
    mac_address: str
    status: str = "online"
    simulated: bool = True


@dataclass
class NetworkConnection:
    connection_id: str
    source_device_id: str
    target_device_id: str
    connection_type: str = "ethernet"
    status: str = "active"
    simulated: bool = True


@dataclass
class Campus:
    name: str
    departments: List[Department] = field(default_factory=list)
    devices: List[NetworkDevice] = field(default_factory=list)
    connections: List[NetworkConnection] = field(default_factory=list)
