
from app.simulation.campus_generator import generate_campus

campus = generate_campus()

print("\n===== TWINGUARD EDGE CAMPUS SIMULATION =====")
print("Campus:", campus.name)

print("\nDepartments:", len(campus.departments))
print("Total devices:", len(campus.devices))
print("Total connections:", len(campus.connections))

for department in campus.departments:
    devices = [
        device for device in campus.devices
        if device.department_id == department.department_id
    ]

    print(f"\n{department.name}")
    print("Building:", department.building)
    print("Devices:", len(devices))

print("\nSimulation data:", "SIMULATED")
