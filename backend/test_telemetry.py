
from app.simulation.campus_generator import generate_campus
from app.simulation.telemetry_generator import generate_telemetry


campus = generate_campus()

telemetry = generate_telemetry(campus)

print("\n===== TWINGUARD EDGE TELEMETRY =====")

print("Campus:", campus.name)
print("Total devices monitored:", len(telemetry))

print("\nFirst 5 device measurements:")

for record in telemetry[:5]:
    print("\nDevice:", record["device_name"])
    print("Department:", record["department_id"])
    print("Status:", record["status"])
    print("RX:", record["bandwidth_rx_mbps"], "Mbps")
    print("TX:", record["bandwidth_tx_mbps"], "Mbps")
    print("Latency:", record["latency_ms"], "ms")
    print("Packet loss:", record["packet_loss_percent"], "%")

print("\nData source: SIMULATED")
