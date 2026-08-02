#!/usr/bin/env python3
"""
quic_probe.py — минимальный HTTP/3-клиент на aioquic для проверки реальной
пропускной способности через QUIC (UDP 443), а не просто handshake.

Нужен отдельно от curl, потому что стандартная сборка curl в Debian/Ubuntu
обычно не включает HTTP/3 (нет ngtcp2/quiche в libcurl). aioquic — чистый
Python + pip, HTTP/3 "из коробки".

Установка (один раз):
    pip install aioquic --break-system-packages

Использование:
    python3 quic_probe.py <host> <path> [--range-bytes N] [--timeout SEC]

Пример (реальный googlevideo videoplayback URL, host и path раздельно):
    python3 quic_probe.py rr3---sn-xxx.googlevideo.com "/videoplayback?..." \\
        --range-bytes 524288 --timeout 4

Печатает в stdout ОДНО число — количество полученных байт (0 при провале/
таймауте/ошибке handshake). Диагностика — в stderr. Exit code: 0 если
получен хотя бы 1 байт, иначе 1 — удобно использовать в bash-условиях.

ВАЖНО: скрипт написан по документированному API aioquic (проверено на
установленной версии 1.3.0), но НЕ протестирован против реального YouTube/
googlevideo из песочницы (сеть ограничена белым списком доменов, googlevideo
туда не входит). Первый прогон обязательно делать вручную и проверять,
что скрипт вообще может провести QUIC-handshake хоть с каким-то публичным
HTTP/3-сайтом, прежде чем полагаться на него для тюнинга стратегий —
см. раздел self-test ниже.
"""
import argparse
import asyncio
import ssl
import sys

from aioquic.asyncio import connect
from aioquic.asyncio.protocol import QuicConnectionProtocol
from aioquic.h3.connection import H3_ALPN, H3Connection
from aioquic.h3.events import DataReceived, H3Event, HeadersReceived
from aioquic.quic.configuration import QuicConfiguration
from aioquic.quic.events import QuicEvent


class H3Client(QuicConnectionProtocol):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._http = H3Connection(self._quic)
        self.received_bytes = 0
        self.status_code = None
        self.finished = asyncio.Event()

    def quic_event_received(self, event: QuicEvent) -> None:
        for http_event in self._http.handle_event(event):
            self._h3_event_received(http_event)

    def _h3_event_received(self, event: H3Event) -> None:
        if isinstance(event, HeadersReceived):
            for name, value in event.headers:
                if name == b":status":
                    self.status_code = value.decode()
        elif isinstance(event, DataReceived):
            self.received_bytes += len(event.data)
            if event.stream_ended:
                self.finished.set()

    def send_get(self, authority: str, path: str, range_bytes: int) -> None:
        stream_id = self._quic.get_next_available_stream_id()
        headers = [
            (b":method", b"GET"),
            (b":scheme", b"https"),
            (b":authority", authority.encode()),
            (b":path", path.encode()),
            (b"range", f"bytes=0-{range_bytes}".encode()),
        ]
        self._http.send_headers(stream_id=stream_id, headers=headers, end_stream=True)
        self.transmit()


async def run(host: str, path: str, range_bytes: int, timeout: float) -> tuple[int, str]:
    configuration = QuicConfiguration(alpn_protocols=H3_ALPN, is_client=True)
    # Нас интересует, доходят ли данные через DPI/nfqws2, а не валидность
    # цепочки сертификатов — поэтому проверку TLS-цепочки отключаем.
    configuration.verify_mode = ssl.CERT_NONE

    try:
        async with connect(
            host,
            443,
            configuration=configuration,
            create_protocol=H3Client,
            wait_connected=True,
        ) as client:
            client.send_get(host, path, range_bytes)
            try:
                await asyncio.wait_for(client.finished.wait(), timeout=timeout)
            except asyncio.TimeoutError:
                print(
                    f"timeout после {timeout}s, получено {client.received_bytes} байт "
                    f"(status={client.status_code})",
                    file=sys.stderr,
                )
            return client.received_bytes, str(client.status_code)
    except Exception as e:  # noqa: BLE001 — тут нужен любой сбой как "0 байт"
        print(f"error: {type(e).__name__}: {e}", file=sys.stderr)
        return 0, "error"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("host", help="hostname (SNI + authority), без схемы")
    parser.add_argument("path", help="путь + query, например /videoplayback?...")
    parser.add_argument("--range-bytes", type=int, default=65536)
    parser.add_argument("--timeout", type=float, default=4.0)
    args = parser.parse_args()

    received, status = asyncio.run(
        run(args.host, args.path, args.range_bytes, args.timeout)
    )
    print(f"http_status={status}", file=sys.stderr)
    print(received)
    sys.exit(0 if received > 0 else 1)


if __name__ == "__main__":
    main()
