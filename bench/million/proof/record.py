#!/usr/bin/env python3
"""Records a real page in headless Firefox, as screenshots and a video.

    ./record.py URL OUT SECONDS [--port 2831] [--every 1.0]

Each frame is what Firefox really drew, taken with its Marionette protocol.
Nothing is rendered or drawn afterwards, besides joining the frames with ffmpeg.
SIGTERM ends the recording early and still writes the video.
"""
import argparse, base64, json, os, shutil, signal, socket, subprocess, tempfile, time


class Firefox:
    def __init__(self, port):
        self.profile = tempfile.mkdtemp(prefix="stampede-proof-")
        with open(os.path.join(self.profile, "user.js"), "w") as prefs:
            for line in [
                f'user_pref("marionette.port", {port});',
                'user_pref("datareporting.policy.dataSubmissionEnabled", false);',
                'user_pref("browser.shell.checkDefaultBrowser", false);',
                'user_pref("network.http.phishy-userpass-length", 255);',
                'user_pref("network.auth.confirmAuth.enabled", false);',
                'user_pref("network.websocket.allowInsecureFromHTTPS", true);',
            ]:
                prefs.write(line + "\n")
        self.process = subprocess.Popen(
            ["firefox", "--headless", "--marionette", "--no-remote", "--profile", self.profile],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(120):
            try:
                self.sock = socket.create_connection(("127.0.0.1", port))
                break
            except OSError:
                time.sleep(0.5)
        self.buffer, self.id = b"", 0
        self.read()
        self.call("WebDriver:NewSession", {"strictFileInteractability": False})

    def read(self):
        while b":" not in self.buffer:
            self.buffer += self.sock.recv(65536)
        size, rest = self.buffer.split(b":", 1)
        size = int(size)
        while len(rest) < size:
            rest += self.sock.recv(65536)
        self.buffer = rest[size:]
        return json.loads(rest[:size])

    def call(self, name, params=None):
        self.id += 1
        message = json.dumps([0, self.id, name, params or {}]).encode()
        self.sock.sendall(str(len(message)).encode() + b":" + message)
        _, _, error, result = self.read()
        if error:
            raise RuntimeError(f"{name}: {error}")
        return result

    def close(self):
        self.process.terminate()
        self.process.wait()
        shutil.rmtree(self.profile, ignore_errors=True)


stopping = []


def navigate(browser, url):
    """A page may not be up yet, so keeps trying for a minute."""
    for _ in range(30):
        try:
            browser.call("WebDriver:Navigate", {"url": url})
            return
        except RuntimeError:
            time.sleep(2)
    browser.call("WebDriver:Navigate", {"url": url})


def main():
    signal.signal(signal.SIGTERM, lambda *_: stopping.append(True))
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("out")
    parser.add_argument("seconds", type=float)
    parser.add_argument("--port", type=int, default=2831)
    parser.add_argument("--every", type=float, default=1.0)
    parser.add_argument("--width", type=int, default=1400)
    parser.add_argument("--height", type=int, default=900)
    args = parser.parse_args()

    frames = os.path.join(args.out, "frames")
    os.makedirs(frames, exist_ok=True)
    browser = Firefox(args.port)
    try:
        browser.call("WebDriver:SetWindowRect", {"width": args.width, "height": args.height})
        navigate(browser, args.url)
        started, frame = time.time(), 0
        while time.time() - started < args.seconds and not stopping:
            due = started + frame * args.every
            time.sleep(max(0, due - time.time()))
            shot = browser.call("WebDriver:TakeScreenshot", {"full": False})["value"]
            with open(os.path.join(frames, f"{frame:06d}.png"), "wb") as file:
                file.write(base64.b64decode(shot))
            frame += 1
    finally:
        browser.close()

    rate = 1 / args.every
    video = os.path.join(args.out, "recording.mp4")
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", str(rate), "-i",
                    os.path.join(frames, "%06d.png"), "-vf", "pad=ceil(iw/2)*2:ceil(ih/2)*2",
                    "-c:v", "libx264", "-pix_fmt", "yuv420p", "-r", "30", video], check=True)
    print(f"{args.out}: {frame} frames, {os.path.getsize(video) // 1024} KB")


main()
