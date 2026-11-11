"""Validate delegated Entra v2 access tokens and forward one MCP route."""

import argparse
import os
import re
import sys
from http.client import HTTPConnection, HTTPException
from http.server import BaseHTTPRequestHandler, HTTPServer
from uuid import UUID

import jwt


class EntraAuthorization:
    def __init__(self, tenant, audience, client, principal, scope):
        self.tenant, self.audience = tenant, audience
        self.client, self.principal, self.scope = client, principal, scope
        self.issuer = f"https://login.microsoftonline.com/{tenant}/v2.0"
        self.keys = jwt.PyJWKClient(
            f"https://login.microsoftonline.com/{tenant}/discovery/v2.0/keys", timeout=5
        )

    def __call__(self, token):
        key = self.keys.get_signing_key_from_jwt(token).key
        claims = jwt.decode(token, key, algorithms=["RS256"], issuer=self.issuer,
                            audience=self.audience,
                            options={"require": ["exp", "iat", "nbf"], "strict_aud": True})
        scope = claims.get("scp")
        return (claims.get("ver") == "2.0" and claims.get("tid") == self.tenant
                and claims.get("azp") == self.client and claims.get("oid") == self.principal
                and isinstance(scope, str) and self.scope in scope.split())


class Gateway(BaseHTTPRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def log_message(self, *_args):
        pass

    def reject(self, status, **headers):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()

    def relay(self):
        if self.path != "/mcp":
            return self.reject(404)
        if "Origin" in self.headers:
            return self.reject(403)
        authorization = self.headers.get_all("Authorization", [])
        match = re.fullmatch(r"Bearer ([A-Za-z0-9_.-]{1,8192})", authorization[0],
                             re.IGNORECASE) if len(authorization) == 1 else None
        try:
            authorized = match and self.server.authorize(match[1])
        except (jwt.PyJWTError, ValueError, TypeError, OSError):
            authorized = False
        if not authorized:
            return self.reject(401, **{"WWW-Authenticate": "Bearer"})

        try:
            length = int(self.headers.get("Content-Length", "0"))
            if not 0 <= length <= 16384 or "Transfer-Encoding" in self.headers:
                return self.reject(400)
            body = self.rfile.read(length) if length else None
        except (ValueError, TimeoutError):
            return self.reject(400)
        headers = {name: self.headers[name] for name in
                   ("Accept", "Content-Type", "MCP-Protocol-Version") if name in self.headers}
        headers["Authorization"] = "Bearer " + self.server.upstream_token
        upstream = HTTPConnection("127.0.0.1", 8765, timeout=20)
        try:
            upstream.request(self.command, "/mcp", body=body, headers=headers)
            response = upstream.getresponse()
            data = response.read(65537)
            if len(data) > 65536:
                return self.reject(502)
        except (HTTPException, OSError):
            return self.reject(502)
        finally:
            upstream.close()
        self.send_response(response.status)
        for name in ("Content-Type", "Allow"):
            if response.getheader(name):
                self.send_header(name, response.getheader(name))
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_POST = do_GET = do_DELETE = relay


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("tenant", "audience", "client", "principal"):
        parser.add_argument("--" + name, required=True, type=UUID)
    parser.add_argument("--scope", default="Mcp.Read")
    args = parser.parse_args()
    token = os.environ.pop("BIM_BRIDGE_COWORK_LOOPBACK_TOKEN", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{32,256}", token):
        parser.error("Set BIM_BRIDGE_COWORK_LOOPBACK_TOKEN to the adapter's loopback secret")
    with HTTPServer(("127.0.0.1", 8766), Gateway) as server:
        server.authorize = EntraAuthorization(
            str(args.tenant), str(args.audience), str(args.client), str(args.principal), args.scope
        )
        server.upstream_token = token
        print("OAuth gateway listening on http://127.0.0.1:8766/mcp", file=sys.stderr, flush=True)
        server.serve_forever()


if __name__ == "__main__":
    main()
