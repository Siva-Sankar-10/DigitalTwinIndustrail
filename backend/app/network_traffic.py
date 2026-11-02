import threading
import time
from datetime import datetime, timezone
from typing import Optional

import psutil


class NetworkTrafficCollector:
    """
    Collects actual network-interface traffic counters
    from the Windows laptop.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._previous = {}

    def collect(self, interface_alias: str = "Wi-Fi"):
        interface_alias = interface_alias.strip()

        if not interface_alias:
            raise ValueError("Interface alias cannot be empty.")

        interfaces = psutil.net_io_counters(pernic=True)

        if not interfaces:
            raise RuntimeError("No network interfaces were found.")

        # Match the requested Windows network interface.
        actual_name = next(
            (
                name
                for name in interfaces
                if name.casefold() == interface_alias.casefold()
            ),
            None,
        )

        if actual_name is None:
            raise ValueError(
                f"Interface '{interface_alias}' not found. "
                f"Available interfaces: {list(interfaces.keys())}"
            )

        stats = interfaces[actual_name]
        now = time.monotonic()

        with self._lock:
            previous = self._previous.get(actual_name)

            download_rate = 0.0
            upload_rate = 0.0
            interval = None
            rate_available = False

            if previous is not None:
                previous_time = previous["time"]
                elapsed = now - previous_time

                if elapsed > 0:
                    received_delta = max(
                        0,
                        stats.bytes_recv - previous["bytes_recv"],
                    )

                    sent_delta = max(
                        0,
                        stats.bytes_sent - previous["bytes_sent"],
                    )

                    download_rate = received_delta / elapsed
                    upload_rate = sent_delta / elapsed

                    interval = round(elapsed, 3)
                    rate_available = True

            self._previous[actual_name] = {
                "time": now,
                "bytes_recv": stats.bytes_recv,
                "bytes_sent": stats.bytes_sent,
            }

        return {
            "data_source": "REAL_WINDOWS_INTERFACE",
            "interface": actual_name,
            "timestamp": datetime.now(
                timezone.utc
            ).isoformat(),

            "rate_available": rate_available,
            "sample_interval_seconds": interval,

            "download_bytes_per_sec": round(download_rate, 2),
            "upload_bytes_per_sec": round(upload_rate, 2),

            "download_mbps": round(
                download_rate * 8 / 1_000_000, 4
            ),
            "upload_mbps": round(
                upload_rate * 8 / 1_000_000, 4
            ),

            "bytes_received_total": stats.bytes_recv,
            "bytes_sent_total": stats.bytes_sent,

            "packets_received_total": stats.packets_recv,
            "packets_sent_total": stats.packets_sent,

            "errors_received": stats.errin,
            "errors_sent": stats.errout,

            "packets_dropped_in": stats.dropin,
            "packets_dropped_out": stats.dropout,
        }


network_traffic_collector = NetworkTrafficCollector()