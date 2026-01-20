import json
import struct
from socket import socket, AF_INET, IPPROTO_TCP, SOCK_STREAM, TCP_NODELAY
from typing import Any, Optional


HOST = "localhost"
PORT = 9999


class ReaperClient:
    def __init__(self, host: str = HOST, port: int = PORT):
        self.host = host
        self.port = port
        self._conn = None
        self._request_id = 0
        self._holding = False

    def connect(self) -> None:
        if self._conn:
            return
        self._conn = socket(AF_INET, SOCK_STREAM)
        self._conn.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
        self._conn.connect((self.host, self.port))
        print(f"Connected to {self.host}:{self.port}")

    def close(self) -> None:
        if self._conn:
            self._conn.close()
            self._conn = None

    def _send(self, data: bytes) -> None:
        if not self._conn:
            raise RuntimeError("Not connected")
        self._conn.sendall(struct.pack("<I", len(data)) + data)

    def _recv_exact(self, n: int) -> bytes:
        if not self._conn:
            raise RuntimeError("Not connected")
        buf = bytearray()
        while len(buf) < n:
            chunk = self._conn.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("socket closed")
            buf.extend(chunk)
        return bytes(buf)

    def _recv(self) -> dict:
        raw = self._recv_exact(4)
        length = struct.unpack("<I", raw)[0]
        return json.loads(self._recv_exact(length).decode("utf-8"))

    def _call(self, name: str, *args) -> Any:
        self._request_id += 1
        req = json.dumps(
            {"id": self._request_id, "type": "call", "name": name, "args": list(args)},
            ensure_ascii=False,
        ).encode("utf-8")

        self._send(req)
        resp = self._recv()

        if resp.get("type") == "error":
            raise RuntimeError(resp.get("traceback", "unknown error"))
        return resp.get("value")

    def _control(self, cmd: str) -> None:
        self._request_id += 1
        req = json.dumps(
            {"id": self._request_id, "type": "control", "cmd": cmd}, ensure_ascii=False
        ).encode("utf-8")
        self._send(req)
        resp = self._recv()

        if resp.get("type") == "error":
            raise RuntimeError(resp.get("traceback"))

    def hold(self):
        class HoldCtx:
            def __init__(self, client):
                self.client = client

            def __enter__(self):
                self.client._control("HOLD")
                self.client._holding = True
                return self

            def __exit__(self, *args):
                self.client._holding = False
                self.client._control("RELEASE")

        return HoldCtx(self)

    def __getattr__(self, name: str):
        def proxy(*args):
            return self._call(name, *args)

        proxy.__name__ = name
        return proxy


reaper = ReaperClient()


def timer(label: str, fn):
    import time

    t0 = time.perf_counter()
    fn()
    elapsed = time.perf_counter() - t0
    print(f"{label}_elapsed_seconds: {elapsed:.6f}")


def main():
    n = 100

    reaper.connect()

    print("\n=== hold mode test ===")

    def do_hold():
        with reaper.hold():
            markers = []
            for i in range(n):
                idx = reaper.AddProjectMarker(0, 0, i, 0, f"hold{i + 1}", i + 1)
                markers.append(idx)

            for idx in markers:
                reaper.DeleteProjectMarker(0, idx, 0)

    timer("hold", do_hold)

    print("\n=== no_hold mode test ===")

    def do_nohold():
        markers = []
        for i in range(n):
            idx = reaper.AddProjectMarker(0, 0, i + 0.5, 0, f"nohold{i + 1}", i + 1)
            markers.append(idx)

        for idx in markers:
            reaper.DeleteProjectMarker(0, idx, 0)

    timer("no_hold", do_nohold)

    reaper.close()


if __name__ == "__main__":
    try:
        main()
    except ConnectionError as e:
        print(f"Connection failed: {e}")
        print("Please load and run api_server.lua in REAPER first")
        exit(1)
    except RuntimeError as e:
        print(f"\nError: {e}")
        exit(1)
