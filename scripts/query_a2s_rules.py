#!/usr/bin/env python3

from __future__ import annotations

import argparse
import bz2
import json
import socket
import struct
import sys
import time
import zlib
from dataclasses import dataclass


SINGLE_HEADER = b"\xff\xff\xff\xff"
SPLIT_HEADER = b"\xfe\xff\xff\xff"
A2S_RULES = b"V"
S2C_CHALLENGE = b"A"
S2A_RULES = b"E"


class QueryError(RuntimeError):
    pass


@dataclass
class SplitResponse:
    total: int
    compressed: bool
    fragments: dict[int, bytes]
    decompressed_size: int | None = None
    checksum: int | None = None


def decode_split_packet(packet: bytes) -> tuple[int, int, int, bool, bytes, int | None, int | None]:
    if len(packet) < 12 or not packet.startswith(SPLIT_HEADER):
        raise QueryError("invalid Source split packet")

    request_id = struct.unpack_from("<I", packet, 4)[0]
    compressed = bool(request_id & 0x80000000)
    response_id = request_id & 0x7FFFFFFF
    total = packet[8]
    number = packet[9]
    offset = 12  # bytes 10-11 are the advertised fragment size
    decompressed_size = None
    checksum = None

    if compressed and number == 0:
        if len(packet) < 20:
            raise QueryError("compressed split packet is missing metadata")
        decompressed_size, checksum = struct.unpack_from("<II", packet, 12)
        offset = 20

    if total == 0 or number >= total:
        raise QueryError(f"invalid split packet number {number}/{total}")

    return (
        response_id,
        total,
        number,
        compressed,
        packet[offset:],
        decompressed_size,
        checksum,
    )


def receive_response(sock: socket.socket) -> bytes:
    original_timeout = sock.gettimeout()
    deadline = None if original_timeout is None else time.monotonic() + original_timeout

    def receive_packet() -> bytes:
        if deadline is not None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError("A2S response deadline exceeded")
            sock.settimeout(remaining)
        return sock.recv(65535)

    try:
        packet = receive_packet()
        if packet.startswith(SINGLE_HEADER):
            return packet[4:]
        if not packet.startswith(SPLIT_HEADER):
            raise QueryError("response has an unknown packet header")

        response_id, total, number, compressed, payload, size, checksum = decode_split_packet(packet)
        response = SplitResponse(total=total, compressed=compressed, fragments={number: payload})
        response.decompressed_size = size
        response.checksum = checksum

        while len(response.fragments) < response.total:
            packet = receive_packet()
            if not packet.startswith(SPLIT_HEADER):
                continue

            current_id, current_total, current_number, current_compressed, payload, size, checksum = (
                decode_split_packet(packet)
            )
            if current_id != response_id:
                continue
            if current_total != response.total or current_compressed != response.compressed:
                raise QueryError("inconsistent split response metadata")

            response.fragments[current_number] = payload
            if size is not None:
                response.decompressed_size = size
            if checksum is not None:
                response.checksum = checksum

        data = b"".join(response.fragments[index] for index in range(response.total))
        if not response.compressed:
            return data[4:] if data.startswith(SINGLE_HEADER) else data

        data = bz2.decompress(data)
        if response.decompressed_size is not None and len(data) != response.decompressed_size:
            raise QueryError(
                f"decompressed response size mismatch: {len(data)} != {response.decompressed_size}"
            )
        if response.checksum is not None and (zlib.crc32(data) & 0xFFFFFFFF) != response.checksum:
            raise QueryError("decompressed response checksum mismatch")
        return data[4:] if data.startswith(SINGLE_HEADER) else data
    finally:
        sock.settimeout(original_timeout)


def read_cstring(data: bytes, offset: int) -> tuple[str, int]:
    end = data.find(b"\0", offset)
    if end == -1:
        raise QueryError("unterminated string in A2S_RULES response")
    return data[offset:end].decode("utf-8", errors="replace"), end + 1


def parse_rules_response(data: bytes) -> list[tuple[str, str]]:
    if len(data) < 3 or data[:1] != S2A_RULES:
        response_type = data[:1].hex() if data else "empty"
        raise QueryError(f"expected S2A_RULES response, received {response_type}")

    count = struct.unpack_from("<H", data, 1)[0]
    offset = 3
    rules: list[tuple[str, str]] = []
    for _ in range(count):
        name, offset = read_cstring(data, offset)
        value, offset = read_cstring(data, offset)
        rules.append((name, value))
    return rules


def query_rules(host: str, port: int, timeout: float) -> list[tuple[str, str]]:
    errors: list[str] = []
    for family, socktype, proto, _, address in socket.getaddrinfo(
        host, port, type=socket.SOCK_DGRAM
    ):
        try:
            with socket.socket(family, socktype, proto) as sock:
                sock.settimeout(timeout)
                sock.connect(address)
                challenge = b"\xff\xff\xff\xff"

                for _ in range(3):
                    sock.send(SINGLE_HEADER + A2S_RULES + challenge)
                    response = receive_response(sock)
                    if response[:1] == S2A_RULES:
                        return parse_rules_response(response)
                    if len(response) != 5 or response[:1] != S2C_CHALLENGE:
                        raise QueryError("server returned neither a challenge nor rules")
                    challenge = response[1:5]

                raise QueryError("server issued too many consecutive challenges")
        except (OSError, QueryError) as error:
            errors.append(f"{address}: {error}")

    raise QueryError("; ".join(errors) if errors else "host resolution returned no addresses")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Query Source A2S_RULES over UDP")
    parser.add_argument("host", help="SRCDS hostname or IP address")
    parser.add_argument("--port", type=int, default=27015, help="query port (default: 27015)")
    parser.add_argument("--timeout", type=float, default=3.0, help="socket timeout in seconds")
    parser.add_argument("--json", action="store_true", help="print a JSON object")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        rules = query_rules(args.host, args.port, args.timeout)
    except QueryError as error:
        print(f"A2S_RULES query failed: {error}", file=sys.stderr)
        return 1

    sorted_rules = sorted(rules, key=lambda item: item[0].casefold())
    if args.json:
        print(json.dumps(dict(sorted_rules), ensure_ascii=False, indent=2, sort_keys=True))
    else:
        for name, value in sorted_rules:
            print(f"{name}={value}")
        print(f"\nRule count: {len(sorted_rules)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
