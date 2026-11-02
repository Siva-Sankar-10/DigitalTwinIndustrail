from typing import Any


LATENCY_WARNING_MS = 100.0
LATENCY_CRITICAL_MS = 250.0

PACKET_LOSS_WARNING_PERCENT = 2.0
PACKET_LOSS_CRITICAL_PERCENT = 5.0

OFFLINE_STATUSES = {"offline", "down", "unreachable"}


def _number(value: Any) -> float | None:
    try:
        if value is None:
            return None

        number = float(value)

        if not (number == number):
            return None

        return number

    except (TypeError, ValueError):
        return None


def analyze_telemetry(payload: dict) -> dict:
    """Analyze telemetry records and return rule-based alerts."""

    # Your FastAPI telemetry API uses the "telemetry" field.
    # "devices" is also supported for compatibility.
    records = payload.get("telemetry", payload.get("devices", []))

    if not isinstance(records, list):
        raise ValueError("Telemetry records must be a list.")

    alerts = []
    sources = set()
    affected_devices = set()

    for device in records:
        if not isinstance(device, dict):
            continue

        device_id = str(device.get("device_id", "unknown"))
        device_name = device.get("device_name", device_id)

        source = str(
            device.get(
                "source",
                payload.get("data_source", "UNKNOWN"),
            )
        ).upper()

        sources.add(source)

        status = str(device.get("status", "unknown")).lower()
        latency = _number(device.get("latency_ms"))
        packet_loss = _number(
            device.get("packet_loss_percent")
        )

        def add_alert(fault_type, severity, detail, value=None):
            alerts.append({
                "device_id": device_id,
                "device_name": device_name,
                "department_id": device.get("department_id"),
                "ip_address": device.get("ip_address"),
                "fault_type": fault_type,
                "severity": severity,
                "message": detail,
                "measured_value": value,
                "source": source,
            })
            affected_devices.add(device_id)

        if status in OFFLINE_STATUSES:
            add_alert(
                "DEVICE_OFFLINE",
                "CRITICAL",
                f"{device_name} is reported offline.",
                status,
            )

        if latency is not None:
            if latency > LATENCY_CRITICAL_MS:
                add_alert(
                    "HIGH_LATENCY",
                    "CRITICAL",
                    "Latency exceeds the critical threshold.",
                    latency,
                )
            elif latency > LATENCY_WARNING_MS:
                add_alert(
                    "HIGH_LATENCY",
                    "WARNING",
                    "Latency exceeds the warning threshold.",
                    latency,
                )

        if packet_loss is not None:
            if packet_loss > PACKET_LOSS_CRITICAL_PERCENT:
                add_alert(
                    "PACKET_LOSS",
                    "CRITICAL",
                    "Packet loss exceeds the critical threshold.",
                    packet_loss,
                )
            elif packet_loss > PACKET_LOSS_WARNING_PERCENT:
                add_alert(
                    "PACKET_LOSS",
                    "WARNING",
                    "Packet loss exceeds the warning threshold.",
                    packet_loss,
                )

    critical_count = sum(
        alert["severity"] == "CRITICAL" for alert in alerts
    )

    warning_count = sum(
        alert["severity"] == "WARNING" for alert in alerts
    )

    return {
        "engine": "RULE_BASED_FAULT_DETECTION",
        "simulation": bool(sources) and sources == {"SIMULATED"},
        "sources": sorted(sources),
        "summary": {
            "devices_analyzed": len(records),
            "total_alerts": len(alerts),
            "critical_alerts": critical_count,
            "warning_alerts": warning_count,
            "affected_devices": len(affected_devices),
            "healthy_devices": max(
                0, len(records) - len(affected_devices)
            ),
        },
        "thresholds": {
            "latency_warning_ms": LATENCY_WARNING_MS,
            "latency_critical_ms": LATENCY_CRITICAL_MS,
            "packet_loss_warning_percent":
                PACKET_LOSS_WARNING_PERCENT,
            "packet_loss_critical_percent":
                PACKET_LOSS_CRITICAL_PERCENT,
        },
        "alerts": alerts,
    }