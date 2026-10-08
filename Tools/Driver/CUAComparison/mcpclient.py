"""A minimal MCP stdio client: one JSON-RPC message per line, the framing both drivers speak."""
import json, subprocess, time

class MCPClient:
    def __init__(self, argv, env=None, stderr=None):
        self.proc = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=stderr or subprocess.DEVNULL, env=env, bufsize=0)
        self.next_id = 0
        self.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "driver-compare", "version": "1"}})
        self.notify("notifications/initialized")

    @property
    def pid(self): return self.proc.pid

    def notify(self, method, params=None):
        self._write({"jsonrpc": "2.0", "method": method, **({"params": params} if params else {})})

    def _write(self, message):
        self.proc.stdin.write((json.dumps(message) + "\n").encode())
        self.proc.stdin.flush()

    def request(self, method, params):
        self.next_id += 1
        self._write({"jsonrpc": "2.0", "id": self.next_id, "method": method, "params": params})
        while True:
            line = self.proc.stdout.readline()
            if not line:
                raise RuntimeError(f"server exited ({self.proc.poll()})")
            reply = json.loads(line)
            if reply.get("id") == self.next_id:
                return reply

    def call(self, name, arguments):
        """Returns (seconds, bytes of the reply line, reply)."""
        start = time.perf_counter()
        reply = self.request("tools/call", {"name": name, "arguments": arguments})
        elapsed = time.perf_counter() - start
        return elapsed, len(json.dumps(reply)), reply

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
