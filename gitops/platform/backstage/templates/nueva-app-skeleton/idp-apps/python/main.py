import os
from http.server import HTTPServer, BaseHTTPRequestHandler

APP_NAME = os.environ.get("APP_NAME", "${{ values.appName }}")
APP_PORT = int(os.environ.get("APP_PORT", "${{ values.port }}"))


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/health":
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b"ok")
        else:
            self.send_response(200)
            self.end_headers()
            self.wfile.write(f"Hello from {APP_NAME}!\n".encode())

    def log_message(self, format, *args):
        print(f"[{APP_NAME}] " + format % args)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", APP_PORT), Handler)
    print(f"Starting {APP_NAME} on :{APP_PORT}")
    server.serve_forever()
