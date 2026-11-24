import argparse
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from xml.etree import ElementTree


ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "JukeboxCoreTests" / "Fixtures"


def network_config(directory, port):
    directory.mkdir()
    root = ElementTree.Element("NetworkConfiguration")
    for name, value in {
        "InternalHttpPort": port, "PublicHttpPort": port, "EnableHttps": "false",
        "EnableIPv4": "true", "EnableIPv6": "false", "EnableRemoteAccess": "false",
        "EnableUPnP": "false", "AutoDiscovery": "false",
    }.items():
        ElementTree.SubElement(root, name).text = str(value)
    addresses = ElementTree.SubElement(root, "LocalNetworkAddresses")
    ElementTree.SubElement(addresses, "string").text = "127.0.0.1"
    ElementTree.ElementTree(root).write(directory / "network.xml", encoding="utf-8")


def wait_for_listener(process, port):
    deadline = time.monotonic() + 55
    while process.poll() is None and time.monotonic() < deadline:
        result = subprocess.run(
            ["lsof", "-nP", "-a", "-p", str(process.pid), "-iTCP", "-sTCP:LISTEN", "-Fn"],
            capture_output=True, text=True,
        )
        listeners = {line[1:] for line in result.stdout.splitlines() if line.startswith("n")}
        if listeners:
            if listeners != {f"127.0.0.1:{port}"}:
                raise RuntimeError("The fixture did not bind exclusively to its loopback port")
            return
        time.sleep(0.25)
    raise RuntimeError(f"Stock fixture failed to start (process status {process.poll()})")


class Fixture:
    def __init__(self, port):
        self.base = f"http://127.0.0.1:{port}"
        self.auth = 'MediaBrowser Client="Fixture", Device="Mac", DeviceId="setup", Version="1"'
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, path, body=None, query=None, method=None):
        url = self.base + "/" + path
        if query:
            url += "?" + urllib.parse.urlencode(query)
        request = urllib.request.Request(
            url, data=json.dumps(body).encode() if body is not None else None, method=method,
            headers={"Content-Type": "application/json", "Authorization": self.auth},
        )
        try:
            with self.opener.open(request, timeout=6) as response:
                data = response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{request.get_method()} {path} returned HTTP {error.code}") from None
        return json.loads(data) if data else None

    def provision(self, music, password):
        deadline = time.monotonic() + 45
        while True:
            try:
                info = self.request("System/Info/Public")
                if isinstance(info, dict) and "Version" in info and "StartupWizardCompleted" in info:
                    break
            except (RuntimeError, urllib.error.URLError):
                info = {}
            if time.monotonic() >= deadline:
                fields = sorted(info) if isinstance(info, dict) else []
                raise RuntimeError(f"Server info did not become ready (fields {fields})")
            time.sleep(0.25)
        if not re.fullmatch(r"12\.4(?:\.\d+)?", info["Version"]) or info["StartupWizardCompleted"]:
            raise RuntimeError("Expected an unconfigured stock Jellyfin 12.4 instance")
        print("Disposable Jellyfin " + info["Version"], flush=True)
        admin_password = secrets.token_urlsafe(32)
        self.request("Startup/User")
        self.request("Startup/User", {"Name": "Fixture admin", "Password": admin_password})
        self.request("Startup/RemoteAccess", {
            "EnableRemoteAccess": False, "EnableAutomaticPortMapping": False,
        })
        self.request("Startup/Complete", method="POST")
        session = self.request("Users/AuthenticateByName", {
            "Username": "Fixture admin", "Pw": admin_password,
        })
        self.auth += ', Token="' + session["AccessToken"] + '"'
        self.request("Users/New", {"Name": "Listener", "Password": password})
        self.request(
            "Library/VirtualFolders",
            {"LibraryOptions": {"EnableRealtimeMonitor": False}},
            {"name": "Fixture Music", "collectionType": "music", "paths": str(music),
             "refreshLibrary": "true"},
        )
        owner = session["User"]["Id"]
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            rows = self.request("Items", query={
                "userId": owner, "recursive": "true", "includeItemTypes": "Audio",
            })["Items"]
            songs = {row["Name"]: row["Id"] for row in rows}
            if set(songs) == {"First", "Second"}:
                break
            time.sleep(0.5)
        else:
            raise RuntimeError("Stock Jellyfin did not index the two fixture songs")

        order = [songs["First"], songs["Second"], songs["First"]]
        source = self.request("Playlists", {
            "Name": "Fixture repeats", "MediaType": "Audio", "UserId": owner,
            "IsPublic": True, "Ids": order,
        })
        path = "Playlists/" + source["Id"]
        entries = self.request(path + "/Items", query={"userId": owner})["Items"]
        if [row["Id"] for row in entries] != order:
            raise RuntimeError("Stock Jellyfin did not save all three positions in the source playlist")


def smoke(args, work):
    music = work / "music"
    album = music / "Album"
    album.mkdir(parents=True)
    subprocess.run([
        str(args.ffmpeg), "-nostdin", "-loglevel", "error", "-filter_threads", "1",
        "-i", str(FIXTURES / "bridge.flac"), "-ar", "44100", "-ac", "2",
        "-threads", "1", str(album / "First.flac"),
    ], check=True)
    shutil.copyfile(FIXTURES / "bridge.mp3", album / "Second.mp3")
    with socket.socket() as reservation:
        reservation.bind(("127.0.0.1", 0))
        port = reservation.getsockname()[1]
    config = work / "config"
    network_config(config, port)
    command = [
        str(args.jellyfin), "--datadir", str(work / "data"), "--configdir", str(config),
        "--cachedir", str(work / "cache"), "--logdir", str(work / "logs"),
        "--ffmpeg", str(args.ffmpeg), "--nowebclient",
    ]
    with subprocess.Popen(
        command, cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    ) as server:
        try:
            wait_for_listener(server, port)
            password = secrets.token_urlsafe(32)
            Fixture(port).provision(music, password)
            result = subprocess.run(
                ["swift", "test", "--build-system", "native", "--skip-build",
                 "--scratch-path", str(args.scratch_path), "--filter", "StockJellyfinTests"],
                cwd=ROOT, env=dict(
                    os.environ, JUKEBOX_FIXTURE_PORT=str(port), JUKEBOX_FIXTURE_PASSWORD=password,
                ),
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=150,
            )
            print(result.stdout, flush=True)
            result.check_returncode()
            if not re.search(r"Executed 5 tests, with 0 failures", result.stdout):
                raise RuntimeError("Build the stock test target with -DSTOCK_JELLYFIN_TEST before running")
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=12)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


def main():
    parser = argparse.ArgumentParser(description="Test Jukebox on a disposable Jellyfin 12.4 server on macOS.")
    parser.add_argument("--jellyfin", type=Path, required=True)
    parser.add_argument("--ffmpeg", type=Path, required=True)
    parser.add_argument("--scratch-path", type=Path, required=True, help="SwiftPM build of the stock tests")
    args = parser.parse_args()
    args.jellyfin = args.jellyfin.resolve(strict=True)
    args.ffmpeg = args.ffmpeg.resolve(strict=True)
    args.scratch_path = args.scratch_path.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="jukebox-stock-") as directory:
        smoke(args, Path(directory))


if __name__ == "__main__":
    main()
