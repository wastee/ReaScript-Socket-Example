import ast
import contextlib
import json
import pathlib
import struct
from socket import AF_INET, IPPROTO_TCP, SOCK_STREAM, TCP_NODELAY, socket
from typing import Any, Optional


HOST = "localhost"
PORT = 9999


def _recv_exact(conn: socket, n: int) -> bytes:
    buf = bytearray()
    while len(buf) < n:
        chunk = conn.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("socket closed")
        buf.extend(chunk)
    return bytes(buf)


def _make_proxy(client: "Client", fn_name: str):
    def _proxy(*args):
        return client.call(fn_name, *args)

    _proxy.__name__ = fn_name
    return _proxy


def import_reascript_api(
    reaper_python_path: Optional[str] = None,
    target_globals: Optional[dict[str, Any]] = None,
) -> dict[str, Any]:
    if reaper_python_path is None:
        reaper_python_path = str(pathlib.Path(__file__).parent / "reaper_python.py")
    else:
        reaper_python_path = str(pathlib.Path(reaper_python_path).resolve())

    src = pathlib.Path(reaper_python_path).read_text(encoding="utf-8", errors="replace")
    tree = ast.parse(src)
    reascript_api_names = sorted(
        {
            node.name
            for node in ast.walk(tree)
            if isinstance(node, ast.FunctionDef) and node.name.startswith("RPR_")
        }
    )

    if target_globals is None:
        import sys

        target_globals = sys._getframe(1).f_globals

    proxies: dict[str, Any] = {}
    for _name in reascript_api_names:
        proxy = _make_proxy(client, _name)
        proxies[_name] = proxy
        target_globals[_name] = proxy

    return proxies


class Client:
    def __init__(
        self,
        host: str = HOST,
        port: int = PORT,
        timeout_s: Optional[float] = 2.0,
    ):
        self.host = host
        self.port = port
        self.timeout_s = timeout_s

        self._conn: Optional[socket] = None
        self._next_request_id = 1
        self._holding = False

    def connect(self) -> None:
        if self._conn is not None:
            return

        conn = socket(AF_INET, SOCK_STREAM)
        conn.setsockopt(IPPROTO_TCP, TCP_NODELAY, 1)
        if self.timeout_s is not None:
            conn.settimeout(self.timeout_s)

        conn.connect((self.host, self.port))
        self._conn = conn

    def close(self) -> None:
        if self._conn is None:
            return
        try:
            self._conn.close()
        finally:
            self._conn = None
            self._holding = False

    def _connect_if_needed(self) -> None:
        if self._conn is None:
            self.connect()

    def _send_message(self, data: bytes) -> None:
        self._connect_if_needed()
        assert self._conn is not None
        self._conn.sendall(struct.pack("<I", len(data)) + data)

    def _recv_message(self) -> dict[str, Any]:
        assert self._conn is not None
        raw = _recv_exact(self._conn, 4)
        (n,) = struct.unpack("<I", raw)
        resp = json.loads(_recv_exact(self._conn, n).decode("utf-8"))
        if type(resp) is not dict:
            raise ValueError(f"invalid response: {resp!r}")
        return resp

    def _handle(self, resp: dict[str, Any], expected_id: Optional[int] = None) -> Any:
        if expected_id is not None and resp.get("id") != expected_id:
            raise ValueError(
                f"mismatched response: expected id={expected_id}, got={resp!r}"
            )

        resp_type = resp.get("type")
        if resp_type == "result":
            return resp.get("value")
        if resp_type == "error":
            raise RuntimeError(resp.get("traceback", "(no traceback)"))
        raise ValueError(f"unknown response: {resp!r}")

    def _send_control(self, cmd: str) -> None:
        request_id = self._next_request_id
        self._next_request_id += 1

        self._send_message(
            json.dumps(
                {
                    "id": request_id,
                    "type": "control",
                    "cmd": cmd,
                },
                ensure_ascii=False,
            ).encode("utf-8")
        )
        resp = self._recv_message()
        self._handle(resp, expected_id=request_id)

    def call(self, name: str, *args: Any) -> Any:
        request_id = self._next_request_id
        self._next_request_id += 1

        req = json.dumps(
            {
                "id": request_id,
                "type": "call",
                "name": name,
                "args": list(args),
            },
            ensure_ascii=False,
        ).encode("utf-8")

        self._send_message(req)
        resp = self._recv_message()
        return self._handle(resp, expected_id=request_id)

    def release(self) -> None:
        if not self._holding:
            return
        try:
            self._send_control("RELEASE")
        finally:
            self._holding = False

    def hold(self):
        @contextlib.contextmanager
        def _cm():
            if self._holding:
                raise RuntimeError("hold() does not support nesting")
            self._send_control("HOLD")
            self._holding = True
            try:
                yield
            finally:
                self.release()

        return _cm()


client = Client()
import_reascript_api()


def hold():
    return client.hold()
