import hashlib
import ipaddress
import unicodedata
from typing import Optional


def build_network_identity(
    ssid: Optional[str],
    gateway: str,
    subnet: str,
) -> dict:
    """
    Build a stable identity for the currently connected network.

    Uses:
        SSID + Gateway + Subnet

    Does not use BSSID because access points can change
    while remaining part of the same Wi-Fi network.
    """

    normalized_ssid = (
        unicodedata.normalize("NFC", ssid.strip())
        if ssid and ssid.strip()
        else "UNKNOWN_SSID"
    )

    normalized_gateway = str(
        ipaddress.ip_address(gateway.strip())
    )

    normalized_subnet = str(
        ipaddress.ip_network(subnet.strip(), strict=False)
    )

    gateway_ip = ipaddress.ip_address(normalized_gateway)
    subnet_network = ipaddress.ip_network(normalized_subnet)

    if gateway_ip.version != subnet_network.version:
        raise ValueError(
            "Gateway and subnet IP versions do not match."
        )

    identity_source = (
        f"ssid={normalized_ssid.casefold()}|"
        f"gateway={normalized_gateway}|"
        f"subnet={normalized_subnet}"
    )

    fingerprint = hashlib.sha256(
        identity_source.encode("utf-8")
    ).hexdigest()

    return {
        "network_id": f"net_{fingerprint}",
        "network_name": normalized_ssid,
        "ssid": normalized_ssid,
        "gateway": normalized_gateway,
        "subnet": normalized_subnet,
    }