# Answers like tailscale's cmd/nginx-auth: 204 with Tailscale-User for a
# user, 403 for a tagged node, 401 for an address WhoIs does not know. The
# mode comes from a file so one server covers all cases: "user" (as
# alice@github), "user <login>", "tagged" or "unknown". Each lookup is
# logged with the Remote-Addr and Remote-Port it was asked about.
#
#   python3 -I fake-nginx-auth.py <socket> <mode file> <log file>
import http.server, os, socketserver, sys

sock, modefile, logfile = sys.argv[1:4]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with open(logfile, "a") as f:
            f.write("%s %s\n" % (self.headers.get("Remote-Addr"), self.headers.get("Remote-Port")))
        mode = open(modefile).read().split()
        if mode[0] == "user":
            self.send_response(204)
            self.send_header("Tailscale-User", mode[1] if len(mode) > 1 else "alice@github")
        else:
            self.send_response(403 if mode[0] == "tagged" else 401)
        self.end_headers()

    def address_string(self):
        return "unix"

class Server(socketserver.UnixStreamServer):
    def get_request(self):
        conn, _ = super().get_request()
        return conn, ("unix", 0)

if os.path.exists(sock):
    os.remove(sock)
Server(sock, Handler).serve_forever()
