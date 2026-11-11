"""Build a connector-only Cowork ZIP from PowerShell or any Python shell."""

import argparse
import json
import re
import struct
import zlib
from pathlib import Path
from urllib.parse import urlsplit
from zipfile import ZIP_DEFLATED, ZipFile

from streamable_http import TOOL


def icon(size, outline=False):
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    rows = bytearray()
    for y in range(size):
        rows.append(0)
        for x in range(size):
            inside = size // 4 <= x < 3 * size // 4 and size // 4 <= y < 3 * size // 4
            inner = 3 * size // 8 <= x < 5 * size // 8 and 3 * size // 8 <= y < 5 * size // 8
            if outline:
                rows.extend((255, 255, 255, 255) if inside and not inner else (0, 0, 0, 0))
            else:
                rows.extend((255, 255, 255, 255) if inside and not inner else (31, 76, 112, 255))
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))


def https_url(value):
    url = urlsplit(value)
    if (url.scheme != "https" or not url.hostname or url.username or url.password
            or url.query or url.fragment or any(char.isspace() for char in value)):
        raise argparse.ArgumentTypeError("Use an HTTPS URL without credentials, query, or fragment")
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mcp-url", required=True, type=https_url)
    parser.add_argument("--oauth-reference", required=True)
    parser.add_argument("--privacy-url", required=True, type=https_url)
    parser.add_argument("--terms-url", required=True, type=https_url)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_+/\-]{1,256}={0,2}", args.oauth_reference):
        parser.error("Provide the Microsoft OAuth registration reference ID")
    manifest = {
        "$schema": "https://developer.microsoft.com/json-schemas/teams/v1.28/MicrosoftTeams.schema.json",
        "manifestVersion": "1.28",
        "version": "0.1.0",
        "id": "8899af9b-6a47-4725-ac92-c5b6c339e760",
        "developer": {
            "name": "BIM Bridge",
            "websiteUrl": "https://github.com/Sideswipe3751/bim-bridge",
            "privacyUrl": args.privacy_url,
            "termsOfUseUrl": args.terms_url,
        },
        "name": {"short": "BIM Bridge Revit", "full": "BIM Bridge Revit for Copilot Cowork"},
        "description": {
            "short": "Read Revit test document units.",
            "full": "Reads the Revit version and display units of one configured test document.",
        },
        "icons": {"color": "color.png", "outline": "outline.png"},
        "accentColor": "#1F4C70",
        "agentConnectors": [{
            "id": "bim-bridge-revit",
            "displayName": "BIM Bridge Revit",
            "description": "Read version and units from the configured Revit test document.",
            "toolSource": {"remoteMcpServer": {
                "mcpServerUrl": args.mcp_url,
                "mcpToolDescription": {"file": "./tools/revit.json"},
                "authorization": {"type": "OAuthPluginVault", "referenceId": args.oauth_reference},
            }},
        }],
    }
    with ZipFile(args.output, "w", ZIP_DEFLATED) as archive:
        archive.writestr("manifest.json", json.dumps(manifest, indent=2))
        archive.writestr("tools/revit.json", json.dumps({"tools": [TOOL]}, indent=2))
        archive.writestr("color.png", icon(192))
        archive.writestr("outline.png", icon(32, outline=True))


if __name__ == "__main__":
    main()
