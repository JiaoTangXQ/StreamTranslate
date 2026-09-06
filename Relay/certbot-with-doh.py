#!/opt/streamtranslate-certbot/bin/python3
"""Per-process ACME DNS resolution; does not edit system DNS or bypass TLS.

The ECS system resolver times out for the CA names. Only these two CA names use
AliDNS's HTTPS JSON resolver. Certificates are still verified against the
original hostname by Certbot/requests. No proxy or transcript traffic is involved.
"""
import ipaddress
import json
import socket
import sys
import time
import urllib.request
from urllib.parse import urlencode

original = socket.getaddrinfo
allowed = {"acme-v02.api.letsencrypt.org", "acme-staging-v02.api.letsencrypt.org"}
cache = {}


def resolve(host, port, family=0, type=0, proto=0, flags=0):
    if host not in allowed:
        return original(host, port, family, type, proto, flags)
    if host not in cache or cache[host][0] < time.monotonic():
        query = urlencode({"name": host, "type": "A"})
        # No credential, account ID, or user text is sent to the resolver.
        with urllib.request.urlopen("https://dns.alidns.com/resolve?" + query, timeout=10) as response:
            result = json.loads(response.read(65536))
        addresses = [r["data"] for r in result.get("Answer", [])
                     if r.get("type") == 1 and ipaddress.ip_address(r["data"]).is_global]
        if result.get("Status") != 0 or not addresses:
            raise socket.gaierror("ACME DNS resolution failed")
        cache[host] = (time.monotonic() + 60, addresses)
    return [entry for address in cache[host][1]
            for entry in original(address, port, socket.AF_INET, type, proto, flags)]


socket.getaddrinfo = resolve
if __name__ == "__main__":
    from certbot.main import main
    sys.exit(main(sys.argv[1:]))
