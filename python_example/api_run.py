import time
from contextlib import contextmanager

from api_client import RPR_AddProjectMarker, RPR_DeleteProjectMarker, client, hold


@contextmanager
def timer(message: str):
    start = time.perf_counter()
    yield lambda: time.perf_counter() - start
    elapsed = time.perf_counter() - start
    print(f"{message}_elapsed_seconds: {elapsed:.6f}")


def main() -> None:
    n = 100

    client.connect()

    # with hold
    with timer("hold") as elapsed_hold:
        markers_hold = []
        with hold():
            for i in range(n):
                idx = RPR_AddProjectMarker(0, 0, i, 0, f"hold{i + 1}", i + 1)
                markers_hold.append(idx)

            for idx in markers_hold:
                RPR_DeleteProjectMarker(0, idx, 0)

    # without hold
    with timer("no_hold") as elapsed_no_hold:
        markers_nohold = []
        for i in range(n):
            idx = RPR_AddProjectMarker(0, 0, i + 0.5, 0, f"nohold{i + 1}", i + 1)
            markers_nohold.append(idx)

        for idx in markers_nohold:
            RPR_DeleteProjectMarker(0, idx, 0)

    client.close()


if __name__ == "__main__":
    main()
