#!/usr/bin/env python3
"""Owned loopback HTTP budget and process-shutdown acceptance."""
import http.client
import os
import select
import signal
import socket
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

mode, origin = sys.argv[1:3]
address = urlsplit(origin)
assert address.hostname == '127.0.0.1' and address.port != 8090
peers = []
try:
    if mode == 'reads':
        workers, budget = map(int, sys.argv[3:5])
        started = time.monotonic()
        trickles = set()
        for index in range(workers):
            peer = socket.create_connection((address.hostname, address.port), timeout=1)
            peers.append(peer)
            if index % 3 == 1:
                request = b'POST /jobs HTTP/1.1\r\nHost: fixture\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: 1024\r\n\r\nx'
            else:
                request = b'GET /readyz HTTP/1.1\r\nHost: fixture\r\nX-Slow: '
                if index % 3 == 2:
                    trickles.add(peer)
            peer.sendall(request)
        probe = http.client.HTTPConnection(address.hostname, address.port, timeout=.3)
        try:
            probe.request('GET', '/readyz')
            probe.getresponse()
            raise AssertionError('fixture did not occupy the entire HTTP pool')
        except TimeoutError:
            pass
        finally:
            probe.close()
        remaining = set(peers)
        while remaining and time.monotonic() - started < budget + 4:
            for peer in trickles & remaining:
                try:
                    peer.sendall(b'x')
                except OSError:
                    pass
            readable, _, _ = select.select(list(remaining), [], [], .1)
            for peer in readable:
                try:
                    body = peer.recv(4096)
                except ConnectionResetError:
                    body = b''
                if not body:
                    remaining.remove(peer)
        assert not remaining, 'partial requests outlived their cumulative read budget'
        probe = http.client.HTTPConnection(address.hostname, address.port, timeout=2)
        try:
            probe.request('GET', '/readyz')
            response = probe.getresponse()
            response.read()
            assert response.status == 200
        finally:
            probe.close()
        print('HTTP acceptance: full-pool partial heads/bodies/trickles expire and readiness recovers')
    elif mode in ('shutdown', 'shutdown-idle'):
        pid = int(sys.argv[3])
        assert pid > 1
        if mode == 'shutdown':
            peer = socket.create_connection((address.hostname, address.port), timeout=1)
            peers.append(peer)
            peer.sendall(b'GET / HTTP/1.1\r\nHost: fixture\r\n')
            time.sleep(.1)
        os.kill(pid, signal.SIGTERM)
        started = time.monotonic()
        while time.monotonic() - started < 12:
            try:
                # The shell owns wait(); an exited, unreaped child is finished.
                stat = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
                if stat[0] == 'Z':
                    break
            except FileNotFoundError:
                break
            time.sleep(.025)
        else:
            raise AssertionError('TERM did not stop owned HTTP/background tasks')
        print('HTTP acceptance: TERM drains/cancels owned work within the service stop bound')
    else:
        raise AssertionError('unknown acceptance mode')
finally:
    for peer in peers:
        peer.close()
