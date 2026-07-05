#!/usr/bin/env python3
import http.server, threading, socket, select, sys

class ProxyHandler(http.server.BaseHTTPRequestHandler):
    def do_CONNECT(self):
        host, port = self.path.split(':')
        try:
            remote = socket.create_connection((host, int(port)), timeout=15)
            self.send_response(200)
            self.end_headers()
            self._tunnel(self.connection, remote)
        except Exception as e:
            self.send_error(502, str(e))

    def _tunnel(self, a, b):
        while True:
            r, _, _ = select.select([a, b], [], [], 60)
            if not r:
                break
            for s in r:
                data = s.recv(4096)
                if not data:
                    return
                (b if s is a else a).sendall(data)

    def log_message(self, *a):
        pass

srv = http.server.HTTPServer(('127.0.0.1', 18080), ProxyHandler)
print(f"proxy listening on 127.0.0.1:18080", flush=True)
srv.serve_forever()
