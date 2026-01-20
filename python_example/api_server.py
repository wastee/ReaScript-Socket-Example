import json
import struct
import traceback
from typing import Any, Optional

from socket import (
    socket,
    AF_INET,
    SOCK_STREAM,
    SOL_SOCKET,
    SO_REUSEADDR,
    SHUT_RDWR,
    timeout as SocketTimeout,
)

HOST = "localhost"
PORT = 9999


class Server:
    def __init__(self, host: str = HOST, port: int = PORT):
        self._socket = socket(AF_INET, SOCK_STREAM)
        self._socket.setsockopt(SOL_SOCKET, SO_REUSEADDR, 1)
        self._socket.setblocking(False)
        self._socket.bind((host, port))
        self._socket.listen(5)

        self._conn = None
        self._recv_buf = bytearray()
        self._send_buf = bytearray()
        self._expect_len = None
        self._holding = False

    def _reset(self) -> None:
        self._holding = False

        if self._conn is not None:
            try:
                self._conn.shutdown(SHUT_RDWR)
            except Exception:
                pass
            try:
                self._conn.close()
            except Exception:
                pass

        self._conn = None
        self._recv_buf.clear()
        self._send_buf.clear()
        self._expect_len = None

    def _send_message(self, obj) -> None:
        payload = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self._send_buf.extend(struct.pack("<I", len(payload)))
        self._send_buf.extend(payload)

    def _flush_blocking(self) -> None:
        conn = self._conn
        if conn is None or not self._send_buf:
            return
        conn.sendall(self._send_buf)
        self._send_buf.clear()

    def _recv_exact(self, n: int) -> bytes:
        conn = self._conn
        if conn is None:
            raise ConnectionError("no connection")

        buf = bytearray()
        while len(buf) < n:
            try:
                chunk = conn.recv(n - len(buf))
            except SocketTimeout:
                continue
            if not chunk:
                raise ConnectionError("socket closed")
            buf.extend(chunk)
        return bytes(buf)

    def _recv_message(self) -> bytes:
        raw = self._recv_exact(4)
        (n,) = struct.unpack("<I", raw)
        return self._recv_exact(n)

    def _hold_loop(self) -> None:
        conn = self._conn
        if conn is None:
            return

        conn.setblocking(True)
        conn.settimeout(0.1)
        try:
            while self._holding and self._conn is conn:
                try:
                    body = self._recv_message()
                except Exception:
                    self._reset()
                    return

                self._handle(body)
                self._flush_blocking()
        finally:
            conn = self._conn
            if conn is not None:
                conn.setblocking(False)

    def _get_callable(self, name):
        if type(name) is str and name.startswith("RPR_"):
            fn = globals().get(name)
            if callable(fn):
                return fn
        return None

    def _send_result(self, request_id: Optional[int], value: Any) -> None:
        self._send_message({"id": request_id, "type": "result", "value": value})

    def _send_error(self, request_id: Optional[int], traceback_str: str) -> None:
        self._send_message(
            {"id": request_id, "type": "error", "traceback": traceback_str}
        )

    def _handle_call(self, request: dict) -> None:
        args = request.get("args", [])
        if type(args) is not list:
            raise ValueError("args must be a list")

        func = self._get_callable(request.get("name"))
        if func is None:
            raise NameError("function not allowed or not found")

        value = func(*args)
        self._send_result(request.get("id"), value)

    def _handle_control(self, request: dict) -> None:
        ctrl_cmd = request.get("cmd")
        if ctrl_cmd == "HOLD":
            self._handle_hold(request)
        elif ctrl_cmd == "RELEASE":
            self._handle_release(request)
        else:
            raise ValueError(f"unknown control cmd: {ctrl_cmd}")

    def _handle_hold(self, request: dict) -> None:
        self._holding = True
        self._send_result(request.get("id"), None)
        self._flush_blocking()
        self._hold_loop()

    def _handle_release(self, request: dict) -> None:
        self._holding = False
        self._send_result(request.get("id"), None)

    def _handle(self, body: bytes) -> None:
        request_id = None
        try:
            request = json.loads(body.decode("utf-8"))
            if type(request) is not dict:
                raise ValueError("request must be an object")

            request_id = request.get("id")
            req_type = request.get("type")

            if req_type == "call":
                self._handle_call(request)
            elif req_type == "control":
                self._handle_control(request)
            else:
                raise ValueError(f"unsupported request type: {req_type}")

        except Exception:
            self._send_error(request_id, traceback.format_exc())

    def run(self) -> None:
        if self._conn is None:
            try:
                conn, _addr = self._socket.accept()
                conn.setblocking(False)
                self._conn = conn
            except BlockingIOError:
                pass

        conn = self._conn
        if conn is not None:
            try:
                while True:
                    data = conn.recv(4096)
                    if not data:
                        self._reset()
                        break
                    self._recv_buf.extend(data)
                    break
            except BlockingIOError:
                pass
            except Exception:
                self._reset()

        conn = self._conn
        while conn is not None:
            if self._expect_len is None:
                if len(self._recv_buf) < 4:
                    break
                self._expect_len = struct.unpack("<I", self._recv_buf[:4])[0]
                del self._recv_buf[:4]

            if len(self._recv_buf) < self._expect_len:
                break

            size = self._expect_len
            body = bytes(self._recv_buf[:size])
            del self._recv_buf[:size]
            self._expect_len = None
            self._handle(body)
            conn = self._conn

        conn = self._conn
        if conn is not None and self._send_buf:
            try:
                while self._send_buf:
                    sent = conn.send(self._send_buf)
                    if sent <= 0:
                        self._reset()
                        break
                    del self._send_buf[:sent]
                    break
            except BlockingIOError:
                pass
            except Exception:
                self._reset()


server = Server()


def loop() -> None:
    server.run()
    RPR_defer("loop()")


if __name__ == "__main__":
    loop()
