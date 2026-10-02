#!/usr/bin/env python3
"""Minimal static HTTP server with Range support, for BMC virtual media.

python3 -m http.server is not enough to back Redfish virtual media: the
BMC's CD emulation treats the ISO as a random-access block device and
reads it with Range requests.  Stock SimpleHTTPRequestHandler advertises
no Accept-Ranges and always answers 200/full-body, so the BMC gives up
right after its initial HEAD probe (seed attempt #3, 2026-10-02).  This
serves the current directory with single-range GETs (206/Content-Range)
and falls back to a full 200 response for unranged or multi-range
requests, which is legal HTTP.

Usage: range-http.py [--bind ADDRESS] PORT
"""
import argparse
import os
import re
import sys
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer


class RangeHandler(SimpleHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def send_head(self):
        path = self.translate_path(self.path)
        if os.path.isdir(path):
            return super().send_head()
        try:
            f = open(path, "rb")
        except OSError:
            self.send_error(404, "File not found")
            return None
        size = os.fstat(f.fileno()).st_size
        m = re.match(r"bytes=(\d*)-(\d*)$", self.headers.get("Range", ""))
        if not m or not (m.group(1) or m.group(2)):
            self.send_response(200)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Length", str(size))
            self.end_headers()
            return f
        if m.group(1):
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else size - 1
        else:
            # suffix range: last N bytes
            start = max(0, size - int(m.group(2)))
            end = size - 1
        if start >= size:
            self.send_error(416, "Requested Range Not Satisfiable")
            f.close()
            return None
        end = min(end, size - 1)
        f.seek(start)
        self.range_remaining = end - start + 1
        self.send_response(206)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        return f

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "range_remaining", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        del self.range_remaining
        while remaining > 0:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bind", default="")
    ap.add_argument("port", type=int)
    args = ap.parse_args()
    httpd = ThreadingHTTPServer((args.bind, args.port), RangeHandler)
    print("serving on %s:%d" % (args.bind or "0.0.0.0", args.port), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
