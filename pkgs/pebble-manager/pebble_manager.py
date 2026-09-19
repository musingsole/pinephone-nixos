#!/usr/bin/env python3
"""Pebble Manager: CLI, Rebble API client, PBW inspector, and web management portal."""

from __future__ import annotations

import argparse
import io
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from http import HTTPStatus
from http.server import HTTPServer, SimpleHTTPRequestHandler
from typing import Any, Dict, List, Optional, Tuple

REBBLE_API_BASE = "https://appstore-api.rebble.io/api/v1"
REBBLE_STORE_BASE = "https://apps.rebble.io"
DEFAULT_PORT = 9096
DEFAULT_HOST = "127.0.0.1"
SERVICE_NAME = "org.rockwork"
MANAGER_PATH = "/org/rockwork/Manager"
MANAGER_INTERFACE = "org.rockwork.Manager"
WATCH_INTERFACE = "org.rockwork.Pebble"


class DBusError(Exception):
    """Raised when a D-Bus call to org.rockwork fails."""


def run_busctl(args: List[str], timeout: int = 15) -> str:
    """Execute busctl on the user session bus."""
    cmd = ["busctl", "--user"] + args
    try:
        proc = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout,
            check=False,
        )
        if proc.returncode != 0:
            err = proc.stderr.strip() or f"exit code {proc.returncode}"
            raise DBusError(f"busctl error ({' '.join(args[:3])}): {err}")
        return proc.stdout.strip()
    except FileNotFoundError:
        raise DBusError("busctl utility not found in PATH")
    except subprocess.TimeoutExpired:
        raise DBusError(f"busctl call timed out after {timeout}s")


# ---------------------------------------------------------------------------
# Pebble Watch & Daemon Management
# ---------------------------------------------------------------------------

class PebbleController:
    """Interacts with libpebble3d daemon via D-Bus org.rockwork."""

    @staticmethod
    def is_daemon_running() -> bool:
        """Check if org.rockwork is active on the session bus."""
        try:
            res = run_busctl(["status", SERVICE_NAME], timeout=3)
            return bool(res)
        except DBusError:
            return False

    @staticmethod
    def list_watches() -> List[Dict[str, Any]]:
        """List known Pebble watches from org.rockwork.Manager."""
        try:
            out = run_busctl(["call", SERVICE_NAME, MANAGER_PATH, MANAGER_INTERFACE, "ListWatches"])
        except DBusError:
            return []

        full_paths = sorted(set(re.findall(r"/org/rockwork/(?:[0-9a-fA-F]{2}_){5}[0-9a-fA-F]{2}", out)))
        
        watches = []
        for path in full_paths:
            mac = path.replace("/org/rockwork/", "").replace("_", ":").upper()
            connected = False
            last_error = ""
            installed_apps: List[str] = []
            try:
                conn_res = run_busctl(["call", SERVICE_NAME, path, WATCH_INTERFACE, "IsConnected"], timeout=3)
                connected = "b true" in conn_res
            except DBusError:
                pass

            try:
                err_res = run_busctl(["call", SERVICE_NAME, path, WATCH_INTERFACE, "LastError"], timeout=3)
                m = re.search(r's "(.*)"', err_res)
                if m:
                    last_error = m.group(1)
            except DBusError:
                pass

            if connected:
                try:
                    apps_res = run_busctl(["call", SERVICE_NAME, path, WATCH_INTERFACE, "InstalledAppIds"], timeout=5)
                    installed_apps = re.findall(
                        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                        apps_res,
                    )
                except DBusError:
                    pass

            watches.append({
                "address": mac,
                "path": path,
                "connected": connected,
                "last_error": last_error,
                "installed_apps": installed_apps,
            })
        return watches

    @staticmethod
    def get_connected_watch() -> Optional[Dict[str, Any]]:
        """Return the first connected watch, or None."""
        for w in PebbleController.list_watches():
            if w.get("connected"):
                return w
        return None

    @staticmethod
    def scan_watches(timeout: int = 10) -> List[str]:
        """Scan for nearby Pebble watches."""
        try:
            run_busctl(["call", SERVICE_NAME, MANAGER_PATH, MANAGER_INTERFACE, "StartScan"])
        except DBusError as e:
            raise DBusError(f"Failed to start scan: {e}")

        time.sleep(timeout)
        try:
            out = run_busctl(["call", SERVICE_NAME, MANAGER_PATH, MANAGER_INTERFACE, "ScanResults"])
        except DBusError:
            out = ""
        finally:
            try:
                run_busctl(["call", SERVICE_NAME, MANAGER_PATH, MANAGER_INTERFACE, "StopScan"])
            except DBusError:
                pass

        return sorted(set(re.findall(r"(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}", out)))

    @staticmethod
    def connect_watch(address: str, timeout: int = 45) -> bool:
        """Connect to a watch by MAC address."""
        norm_addr = address.strip().upper().replace("_", ":")
        path = f"/org/rockwork/{norm_addr.replace(':', '_')}"

        try:
            run_busctl(["call", SERVICE_NAME, MANAGER_PATH, MANAGER_INTERFACE, "ConnectWatch", "s", norm_addr])
        except DBusError as e:
            raise DBusError(f"ConnectWatch failed: {e}")

        start = time.time()
        while time.time() - start < timeout:
            try:
                conn_res = run_busctl(["call", SERVICE_NAME, path, WATCH_INTERFACE, "IsConnected"], timeout=3)
                if "b true" in conn_res:
                    return True
            except DBusError:
                pass
            time.sleep(1)
        return False

    @staticmethod
    def sideload_app(pbw_path: str, watch_path: Optional[str] = None, timeout: int = 60) -> bool:
        """Sideload a .pbw file onto the connected watch."""
        pbw = pathlib.Path(pbw_path).resolve()
        if not pbw.is_file():
            raise FileNotFoundError(f"PBW file not found: {pbw}")

        if not watch_path:
            connected = PebbleController.get_connected_watch()
            if not connected:
                raise DBusError("No Pebble watch is currently connected.")
            watch_path = connected["path"]

        meta = PBWPackage.inspect(pbw)
        app_uuid = meta.get("uuid", "").lower()

        run_busctl(["call", SERVICE_NAME, watch_path, WATCH_INTERFACE, "SideloadApp", "s", str(pbw)], timeout=10)

        if not app_uuid:
            return True

        start = time.time()
        while time.time() - start < timeout:
            try:
                apps_res = run_busctl(["call", SERVICE_NAME, watch_path, WATCH_INTERFACE, "InstalledAppIds"], timeout=5)
                if app_uuid in apps_res.lower():
                    return True
            except DBusError:
                pass
            time.sleep(1)
        return False

    @staticmethod
    def remove_app(app_uuid: str, watch_path: Optional[str] = None) -> bool:
        """Remove an app by UUID from the watch."""
        if not watch_path:
            connected = PebbleController.get_connected_watch()
            if not connected:
                raise DBusError("No Pebble watch is currently connected.")
            watch_path = connected["path"]

        try:
            run_busctl(["call", SERVICE_NAME, watch_path, WATCH_INTERFACE, "RemoveApp", "s", app_uuid], timeout=10)
            return True
        except DBusError as e:
            raise DBusError(f"Failed to remove app {app_uuid}: {e}")


# ---------------------------------------------------------------------------
# PBW File Inspection
# ---------------------------------------------------------------------------

class PBWPackage:
    """Utilities for inspecting and extracting Pebble .pbw archives."""

    @staticmethod
    def inspect(file_path: pathlib.Path | str) -> Dict[str, Any]:
        """Extract and parse appinfo.json from a .pbw zip bundle."""
        path = pathlib.Path(file_path)
        if not path.is_file():
            raise FileNotFoundError(f"File not found: {path}")

        try:
            with zipfile.ZipFile(path, "r") as z:
                try:
                    with z.open("appinfo.json") as f:
                        data = json.load(f)
                except KeyError:
                    data = {}

                watchapp = data.get("watchapp", {})
                is_watchface = bool(watchapp.get("watchface", False))

                names = z.namelist()
                platforms = []
                for p in ["aplite", "basalt", "chalk", "diorite", "emery"]:
                    if any(p in name for name in names):
                        platforms.append(p)

                return {
                    "uuid": data.get("uuid", ""),
                    "short_name": data.get("shortName", path.stem),
                    "long_name": data.get("longName", data.get("shortName", path.stem)),
                    "company": data.get("companyName", "Unknown"),
                    "version": data.get("versionLabel", "1.0"),
                    "is_watchface": is_watchface,
                    "target_platforms": platforms or data.get("targetPlatforms", []),
                    "file_size": path.stat().st_size,
                    "file_path": str(path.resolve()),
                }
        except zipfile.BadZipFile:
            raise ValueError(f"File is not a valid PBW zip archive: {path}")


# ---------------------------------------------------------------------------
# Rebble App Store Client
# ---------------------------------------------------------------------------

class RebbleStore:
    """Client for querying the Rebble App Store API and resolving PBW links."""

    ALGOLIA_APP_ID = "7683OW76EQ"
    ALGOLIA_API_KEY = "252f4938082b8693a8a9fc0157d1d24f"
    ALGOLIA_INDEX = "rebble-appstore-production"

    @staticmethod
    def search_apps(query: str, limit: int = 20) -> List[Dict[str, Any]]:
        """Search apps on Rebble Appstore using the public Algolia search index."""
        url = f"https://{RebbleStore.ALGOLIA_APP_ID.lower()}-dsn.algolia.net/1/indexes/{RebbleStore.ALGOLIA_INDEX}/query"
        payload = json.dumps({
            "params": f"query={urllib.parse.quote(query.strip())}&hitsPerPage={limit}"
        }).encode("utf-8")
        req = urllib.request.Request(
            url,
            data=payload,
            headers={
                "X-Algolia-Application-Id": RebbleStore.ALGOLIA_APP_ID,
                "X-Algolia-API-Key": RebbleStore.ALGOLIA_API_KEY,
                "Content-Type": "application/json",
                "User-Agent": "PebbleManager/1.0 (PinePhone Pro Mobile NixOS)",
            },
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.URLError as e:
            raise ConnectionError(f"Rebble search request failed: {e}")

        results = []
        raw_items = data.get("hits", []) if isinstance(data, dict) else []
        for item in raw_items:
            screenshots = []
            for s in item.get("screenshot_images", []):
                if isinstance(s, dict):
                    screenshots.append(s.get("144x168", s.get("original", "")))
                elif isinstance(s, str):
                    screenshots.append(s)

            results.append({
                "id": item.get("id", ""),
                "title": item.get("title", ""),
                "developer": item.get("author", item.get("developer", "")),
                "category": item.get("category", ""),
                "type": item.get("type", "watchface"),
                "description": item.get("description", ""),
                "hearts": item.get("hearts", 0),
                "icon": item.get("icon_image", {}).get("80x80", "") if isinstance(item.get("icon_image"), dict) else "",
                "screenshot": screenshots[0] if screenshots else "",
                "pbw_url": item.get("pbw_file", ""),
            })
        return results

    @staticmethod
    def get_app_details(app_id: str) -> Dict[str, Any]:
        """Fetch details for a specific Rebble application by ID."""
        clean_id = app_id.strip()
        url = f"{REBBLE_API_BASE}/apps/id/{clean_id}"
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "PebbleManager/1.0 (PinePhone Pro Mobile NixOS)"},
        )
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                data = json.loads(resp.read().decode("utf-8"))
        except urllib.error.URLError as e:
            raise ConnectionError(f"Rebble API request failed for app {clean_id}: {e}")

        items = data.get("data", []) if isinstance(data, dict) else []
        if not items:
            raise ValueError(f"App not found on Rebble: {clean_id}")

        item = items[0]
        screenshots = []
        for s in item.get("screenshot_images", []):
            if isinstance(s, dict):
                screenshots.append(s.get("144x168", s.get("original", "")))
            elif isinstance(s, str):
                screenshots.append(s)

        latest = item.get("latest_release") or {}
        pbw_url = latest.get("pbw_file") or item.get("pbw", {}).get("file", "")

        return {
            "id": item.get("id", ""),
            "title": item.get("title", ""),
            "developer": item.get("author", item.get("developer", "")),
            "category": item.get("category", ""),
            "type": item.get("type", "watchface"),
            "description": item.get("description", ""),
            "hearts": item.get("hearts", 0),
            "version": latest.get("version", item.get("version", "1.0")),
            "uuid": item.get("uuid", ""),
            "screenshots": screenshots,
            "pbw_url": pbw_url,
        }

    @staticmethod
    def resolve_pbw_url(target: str) -> Tuple[str, str]:
        """
        Given a target (local path, Rebble URL, direct pbw URL, or Rebble app ID),
        returns (download_url_or_filepath, suggested_filename).
        """
        target = target.strip()
        # 1. Local file path
        if os.path.exists(target) and target.endswith(".pbw"):
            return target, os.path.basename(target)

        # 2. Rebble web store URL: https://apps.rebble.io/en_US/application/<id>...
        match = re.search(r"application/([0-9a-fA-F]{24})", target)
        if match:
            app_id = match.group(1)
            details = RebbleStore.get_app_details(app_id)
            pbw_url = details.get("pbw_url")
            if not pbw_url:
                raise ValueError(f"Rebble app {app_id} does not expose a downloadable PBW.")
            safe_title = re.sub(r"[^\w\-_\.]", "_", details.get("title", app_id))
            return pbw_url, f"{safe_title}.pbw"

        # 3. 24-character hex ID directly
        if re.match(r"^[0-9a-fA-F]{24}$", target):
            details = RebbleStore.get_app_details(target)
            pbw_url = details.get("pbw_url")
            if not pbw_url:
                raise ValueError(f"Rebble app {target} does not expose a downloadable PBW.")
            safe_title = re.sub(r"[^\w\-_\.]", "_", details.get("title", target))
            return pbw_url, f"{safe_title}.pbw"

        # 4. Direct HTTP(S) URL
        if target.startswith("http://") or target.startswith("https://"):
            filename = os.path.basename(urllib.parse.urlparse(target).path) or "downloaded.pbw"
            if not filename.endswith(".pbw"):
                filename += ".pbw"
            return target, filename

        raise ValueError(f"Unable to resolve target into a PBW source: {target}")

    @staticmethod
    def download_pbw(url_or_path: str, dest_dir: Optional[pathlib.Path] = None) -> pathlib.Path:
        """Download or copy a PBW to a persistent cache directory."""
        if dest_dir is None:
            cache_home = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
            dest_dir = pathlib.Path(cache_home) / "pebble-manager" / "downloads"
        dest_dir.mkdir(parents=True, exist_ok=True)

        url, filename = RebbleStore.resolve_pbw_url(url_or_path)

        if os.path.exists(url):
            target_path = dest_dir / filename
            if target_path != pathlib.Path(url):
                shutil.copy2(url, target_path)
            return target_path

        target_path = dest_dir / filename
        req = urllib.request.Request(
            url,
            headers={"User-Agent": "PebbleManager/1.0 (PinePhone Pro Mobile NixOS)"},
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            with open(target_path, "wb") as f:
                f.write(resp.read())

        return target_path


# ---------------------------------------------------------------------------
# Embedded Web Server & REST API
# ---------------------------------------------------------------------------

class PebbleManagerRequestHandler(SimpleHTTPRequestHandler):
    """Serves the web dashboard and REST API endpoints."""

    asset_dir: pathlib.Path = pathlib.Path(__file__).parent

    def log_message(self, format: str, *args: Any) -> None:
        if os.environ.get("PEBBLE_MANAGER_DEBUG"):
            super().log_message(format, *args)

    def send_json(self, data: Any, status: int = HTTPStatus.OK) -> None:
        blob = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(blob)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(blob)

    def do_GET(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        query = urllib.parse.parse_qs(parsed.query)

        if path in ("/", "/index.html"):
            dashboard_path = self.asset_dir / "dashboard.html"
            if not dashboard_path.is_file():
                self.send_error(HTTPStatus.NOT_FOUND, "dashboard.html missing")
                return
            with open(dashboard_path, "rb") as f:
                content = f.read()
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(content)))
            self.end_headers()
            self.wfile.write(content)
            return

        if path == "/api/status":
            daemon_ok = PebbleController.is_daemon_running()
            watches = PebbleController.list_watches() if daemon_ok else []
            connected = next((w for w in watches if w.get("connected")), None)
            self.send_json({
                "daemon_running": daemon_ok,
                "watches": watches,
                "connected_watch": connected,
            })
            return

        if path == "/api/search":
            q = query.get("q", [""])[0].strip()
            if not q:
                self.send_json({"results": []})
                return
            try:
                results = RebbleStore.search_apps(q)
                self.send_json({"query": q, "results": results})
            except Exception as e:
                self.send_json({"error": str(e)}, status=HTTPStatus.BAD_GATEWAY)
            return

        if path.startswith("/api/app/"):
            app_id = path.replace("/api/app/", "").strip()
            try:
                details = RebbleStore.get_app_details(app_id)
                self.send_json(details)
            except Exception as e:
                self.send_json({"error": str(e)}, status=HTTPStatus.NOT_FOUND)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")

    def do_POST(self) -> None:
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path
        ctype = self.headers.get("Content-Type", "")

        body: Dict[str, Any] = {}
        uploaded_file: Optional[Tuple[str, bytes]] = None

        if "application/json" in ctype:
            length = int(self.headers.get("Content-Length", 0))
            raw_body = self.rfile.read(length).decode("utf-8")
            try:
                body = json.loads(raw_body)
            except json.JSONDecodeError:
                self.send_json({"error": "Invalid JSON body"}, status=HTTPStatus.BAD_REQUEST)
                return
        elif "multipart/form-data" in ctype:
            content_length = int(self.headers.get("Content-Length", 0))
            raw_data = self.rfile.read(content_length)
            
            boundary = ctype.split("boundary=")[-1].encode("utf-8")
            parts = raw_data.split(b"--" + boundary)
            for part in parts:
                if b'filename="' in part:
                    m = re.search(rb'filename="([^"]+)"', part)
                    fname = m.group(1).decode("utf-8") if m else "uploaded.pbw"
                    header_end = part.find(b"\r\n\r\n")
                    if header_end != -1:
                        file_data = part[header_end + 4 :].rstrip(b"\r\n")
                        uploaded_file = (fname, file_data)
                        break

        if path == "/api/install":
            target = body.get("target") or body.get("url") or body.get("id")
            temp_pbw_path: Optional[pathlib.Path] = None

            try:
                if uploaded_file:
                    fname, fbytes = uploaded_file
                    cache_home = os.environ.get("XDG_CACHE_HOME", os.path.expanduser("~/.cache"))
                    dest_dir = pathlib.Path(cache_home) / "pebble-manager" / "uploads"
                    dest_dir.mkdir(parents=True, exist_ok=True)
                    temp_pbw_path = dest_dir / fname
                    with open(temp_pbw_path, "wb") as f:
                        f.write(fbytes)
                elif target:
                    temp_pbw_path = RebbleStore.download_pbw(target)
                else:
                    self.send_json({"error": "Missing target URL or uploaded file"}, status=HTTPStatus.BAD_REQUEST)
                    return

                meta = PBWPackage.inspect(temp_pbw_path)
                success = PebbleController.sideload_app(str(temp_pbw_path))
                if success:
                    self.send_json({
                        "status": "success",
                        "message": f"Successfully sideloaded {meta.get('short_name')}",
                        "app": meta,
                    })
                else:
                    self.send_json({
                        "status": "timeout",
                        "message": "Upload accepted by companion, but app did not confirm on watch in time.",
                        "app": meta,
                    }, status=HTTPStatus.GATEWAY_TIMEOUT)

            except Exception as e:
                self.send_json({"status": "error", "error": str(e)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if path == "/api/remove":
            uuid = body.get("uuid", "").strip()
            if not uuid:
                self.send_json({"error": "Missing uuid"}, status=HTTPStatus.BAD_REQUEST)
                return
            try:
                PebbleController.remove_app(uuid)
                self.send_json({"status": "success", "removed_uuid": uuid})
            except Exception as e:
                self.send_json({"error": str(e)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if path == "/api/connect":
            address = body.get("address", "").strip()
            if not address:
                self.send_json({"error": "Missing address"}, status=HTTPStatus.BAD_REQUEST)
                return
            try:
                ok = PebbleController.connect_watch(address)
                if ok:
                    self.send_json({"status": "connected", "address": address})
                else:
                    self.send_json({"status": "failed", "error": "Connection timed out"}, status=HTTPStatus.REQUEST_TIMEOUT)
            except Exception as e:
                self.send_json({"error": str(e)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        if path == "/api/scan":
            try:
                found = PebbleController.scan_watches(timeout=8)
                self.send_json({"status": "success", "results": found})
            except Exception as e:
                self.send_json({"error": str(e)}, status=HTTPStatus.INTERNAL_SERVER_ERROR)
            return

        self.send_error(HTTPStatus.NOT_FOUND, "Endpoint not found")


# ---------------------------------------------------------------------------
# CLI Commands
# ---------------------------------------------------------------------------

def cmd_status(args: argparse.Namespace) -> None:
    """Print complete status of BlueZ, libpebble3d, and known watches."""
    print("=== Pebble Manager Status ===")
    
    daemon_ok = PebbleController.is_daemon_running()
    status_sym = "[ok]" if daemon_ok else "[!!]"
    print(f"{status_sym} Companion daemon (org.rockwork): {'Running' if daemon_ok else 'Inactive / Not found'}")

    if not daemon_ok:
        print("     Tip: Start with 'systemctl --user start libpebble3d.service'")
        return

    watches = PebbleController.list_watches()
    if not watches:
        print("[--] No known Pebble watches registered in org.rockwork.")
        print("     Tip: Put watch in Settings > Bluetooth and run 'pebble-manager scan'")
        return

    for w in watches:
        conn_sym = "[ok]" if w["connected"] else "[--]"
        state = "Connected" if w["connected"] else "Disconnected"
        print(f"{conn_sym} Watch {w['address']} ({state})")
        if w["last_error"]:
            print(f"     Last error: {w['last_error']}")
        if w["connected"]:
            apps = w["installed_apps"]
            print(f"     Installed apps ({len(apps)}): {', '.join(apps) if apps else 'None reported'}")


def cmd_scan(args: argparse.Namespace) -> None:
    """Scan for nearby Pebble watches."""
    print(f"Scanning for nearby Pebble watches ({args.timeout}s)...")
    results = PebbleController.scan_watches(timeout=args.timeout)
    if not results:
        print("No Pebble watches found. Ensure Bluetooth pairing screen is open on watch.")
    else:
        print("Discovered Pebble watches:")
        for addr in results:
            print(f"  * {addr}")


def cmd_connect(args: argparse.Namespace) -> None:
    """Connect to a specified or known watch."""
    addr = args.address
    if not addr:
        watches = PebbleController.list_watches()
        if not watches:
            print("No known watches. Specify address: pebble-manager connect AA:BB:CC:DD:EE:FF")
            sys.exit(1)
        addr = watches[0]["address"]

    print(f"Connecting to Pebble {addr} (accept prompt on watch if pairing)...")
    if PebbleController.connect_watch(addr, timeout=args.timeout):
        print(f"[ok] Connected to {addr} successfully.")
    else:
        print(f"[!!] Failed to connect to {addr} within {args.timeout} seconds.")
        sys.exit(1)


def cmd_list(args: argparse.Namespace) -> None:
    """List installed app UUIDs on connected watch."""
    watch = PebbleController.get_connected_watch()
    if not watch:
        print("[!!] No Pebble watch is currently connected.")
        sys.exit(1)

    apps = watch.get("installed_apps", [])
    print(f"Connected Watch: {watch['address']}")
    print(f"Installed Apps ({len(apps)}):")
    for app_uuid in apps:
        print(f"  • {app_uuid}")


def cmd_search(args: argparse.Namespace) -> None:
    """Search Rebble App Store."""
    print(f"Searching Rebble App Store for '{args.query}'...")
    try:
        results = RebbleStore.search_apps(args.query, limit=args.limit)
    except Exception as e:
        print(f"[!!] Search failed: {e}")
        sys.exit(1)

    if not results:
        print("No matching apps found.")
        return

    for item in results:
        t = item["type"].upper()
        hearts = f"♥ {item['hearts']}"
        print(f"\n• {item['title']} [{t}] by {item['developer']} ({hearts})")
        print(f"  ID: {item['id']}")
        if item["category"]:
            print(f"  Category: {item['category']}")
        if item["pbw_url"]:
            print(f"  PBW: {item['pbw_url']}")
        desc = item["description"].replace("\n", " ")[:120]
        if desc:
            print(f"  {desc}...")


def cmd_info(args: argparse.Namespace) -> None:
    """Show details of a local PBW or Rebble app."""
    target = args.target
    if os.path.exists(target) and target.endswith(".pbw"):
        meta = PBWPackage.inspect(target)
        print("=== Local PBW Package Info ===")
        print(f"Title:       {meta['long_name']} ({meta['short_name']})")
        print(f"UUID:        {meta['uuid']}")
        print(f"Company:     {meta['company']}")
        print(f"Version:     {meta['version']}")
        print(f"Type:        {'Watchface' if meta['is_watchface'] else 'Watchapp'}")
        print(f"Platforms:   {', '.join(meta['target_platforms'])}")
        print(f"Size:        {meta['file_size']} bytes")
        print(f"Path:        {meta['file_path']}")
    else:
        try:
            url, filename = RebbleStore.resolve_pbw_url(target)
            print("=== Rebble App Info ===")
            print(f"Resolved PBW: {url}")
            print(f"Filename:     {filename}")
        except Exception as e:
            print(f"[!!] Could not inspect {target}: {e}")
            sys.exit(1)


def cmd_install(args: argparse.Namespace) -> None:
    """Download and sideload a PBW onto the connected watch."""
    target = args.target
    print(f"Resolving PBW source: {target}...")
    try:
        pbw_path = RebbleStore.download_pbw(target)
        meta = PBWPackage.inspect(pbw_path)
        print(f"Downloaded: {meta['long_name']} (v{meta['version']}) by {meta['company']}")
        print(f"UUID: {meta['uuid']}")
    except Exception as e:
        print(f"[!!] Failed to prepare PBW: {e}")
        sys.exit(1)

    print(f"Sideloading to connected Pebble...")
    try:
        ok = PebbleController.sideload_app(str(pbw_path), timeout=args.timeout)
        if ok:
            print(f"[ok] {meta['short_name']} installed successfully on watch!")
        else:
            print(f"[--] Sideload accepted, but app did not report ready in {args.timeout}s.")
    except Exception as e:
        print(f"[!!] Sideload failed: {e}")
        sys.exit(1)


def cmd_remove(args: argparse.Namespace) -> None:
    """Remove an app by UUID."""
    print(f"Removing app {args.uuid} from connected watch...")
    try:
        PebbleController.remove_app(args.uuid)
        print(f"[ok] App {args.uuid} removed.")
    except Exception as e:
        print(f"[!!] Remove failed: {e}")
        sys.exit(1)


def cmd_serve(args: argparse.Namespace) -> None:
    """Run the web management portal daemon."""
    asset_dir = pathlib.Path(args.asset_dir or os.environ.get("PEBBLE_MANAGER_ASSET_DIR", pathlib.Path(__file__).parent)).resolve()
    PebbleManagerRequestHandler.asset_dir = asset_dir

    server_address = (args.listen, args.port)
    httpd = HTTPServer(server_address, PebbleManagerRequestHandler)
    print(f"Starting Pebble Manager web portal at http://{args.listen}:{args.port}/")
    print(f"Serving assets from: {asset_dir}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down portal.")
    finally:
        httpd.server_close()


def cmd_open(args: argparse.Namespace) -> None:
    """Open the web portal in the preferred browser."""
    url = f"http://{args.listen}:{args.port}/"
    print(f"Opening {url}...")
    for launcher in ["chromium", "xdg-open", "gio open"]:
        parts = launcher.split()
        if shutil.which(parts[0]):
            subprocess.Popen(parts + [url])
            return
    print(f"Open {url} manually in your browser.")


# ---------------------------------------------------------------------------
# Argument Parsing
# ---------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(
        prog="pebble-manager",
        description="PinePhone Pebble Smartwatch Manager & Sideloading Utility",
    )
    subparsers = parser.add_subparsers(dest="command", help="Available subcommands")

    # status
    p_status = subparsers.add_parser("status", help="Show daemon, Bluetooth, and watch status")
    p_status.set_defaults(func=cmd_status)

    # scan
    p_scan = subparsers.add_parser("scan", help="Scan for nearby Pebble watches")
    p_scan.add_argument("--timeout", type=int, default=10, help="Scan duration in seconds")
    p_scan.set_defaults(func=cmd_scan)

    # connect
    p_conn = subparsers.add_parser("connect", help="Connect to a Pebble watch")
    p_conn.add_argument("address", nargs="?", help="Watch Bluetooth MAC address (AA:BB:CC:DD:EE:FF)")
    p_conn.add_argument("--timeout", type=int, default=45, help="Connection timeout in seconds")
    p_conn.set_defaults(func=cmd_connect)

    # list
    p_list = subparsers.add_parser("list", help="List installed apps on connected watch")
    p_list.set_defaults(func=cmd_list)

    # search
    p_search = subparsers.add_parser("search", help="Search the Rebble App Store")
    p_search.add_argument("query", help="Search keyword (e.g. 'simplex', 'weather')")
    p_search.add_argument("--limit", type=int, default=10, help="Maximum number of results")
    p_search.set_defaults(func=cmd_search)

    # info
    p_info = subparsers.add_parser("info", help="Inspect metadata for a PBW file or Rebble URL")
    p_info.add_argument("target", help="Path to .pbw file, Rebble URL, or app ID")
    p_info.set_defaults(func=cmd_info)

    # install
    p_install = subparsers.add_parser("install", help="Sideload a PBW onto connected watch")
    p_install.add_argument("target", help="Local .pbw file, Rebble store URL, or app ID")
    p_install.add_argument("--timeout", type=int, default=60, help="Wait timeout for app installation")
    p_install.set_defaults(func=cmd_install)

    # remove
    p_remove = subparsers.add_parser("remove", help="Remove an installed app by UUID")
    p_remove.add_argument("uuid", help="UUID of the app to remove")
    p_remove.set_defaults(func=cmd_remove)

    # serve
    p_serve = subparsers.add_parser("serve", help="Run the background web portal server")
    p_serve.add_argument("--listen", default=DEFAULT_HOST, help=f"Listen address (default: {DEFAULT_HOST})")
    p_serve.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TCP port (default: {DEFAULT_PORT})")
    p_serve.add_argument("--asset-dir", help="Directory containing dashboard.html")
    p_serve.set_defaults(func=cmd_serve)

    # open
    p_open = subparsers.add_parser("open", help="Open web portal in browser")
    p_open.add_argument("--listen", default=DEFAULT_HOST, help="Host of running portal")
    p_open.add_argument("--port", type=int, default=DEFAULT_PORT, help="Port of running portal")
    p_open.set_defaults(func=cmd_open)

    args = parser.parse_args()
    if not hasattr(args, "func"):
        parser.print_help()
        sys.exit(0)

    args.func(args)


if __name__ == "__main__":
    main()
