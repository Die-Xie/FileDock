"""Loopback-only server for isolated updater integration fixtures."""
import functools
import http.server
import pathlib
import sys

root = pathlib.Path(sys.argv[1]).resolve(strict=True)
class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()

handler = functools.partial(Handler, directory=str(root))
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
