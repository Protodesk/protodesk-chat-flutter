"""Capture native chat screens against the checked-in public website content."""
import argparse
import base64
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Directory for the native PNGs")
    parser.add_argument("--device", required=True, help="Android device ID from flutter devices")
    parser.add_argument("--ime-tap", nargs=2, metavar=("X", "Y"), type=int,
                        help="Tap the soft keyboard action at these device pixels; defaults to Enter")
    args = parser.parse_args()
    support = ROOT / "test" / "support"
    fixture = json.loads((support / "android_website_content.json").read_text())
    fixture["logo"] = base64.b64encode((support / "website-logo.png").read_bytes()).decode()
    with tempfile.TemporaryDirectory() as temp:
        defines = Path(temp) / "comparison.json"
        defines.write_text(json.dumps({"CHAT_COMPARISON_FIXTURE": json.dumps(fixture)}))
        output = args.output.resolve()
        output.mkdir(parents=True, exist_ok=True)
        adb = shutil.which("adb") or str(Path(os.environ["ANDROID_HOME"]) / "platform-tools/adb")
        with subprocess.Popen(
            ["flutter", "drive", "--no-pub", "--driver=test_driver/website_comparison.dart",
             "--target=integration_test/website_comparison_test.dart",
             f"--dart-define-from-file={defines}", "-d", args.device],
            cwd=ROOT / "example",
            env={**os.environ, "CHAT_COMPARISON_DIR": str(args.output.resolve())},
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        ) as drive:
            for line in drive.stdout:
                print(line, end="", flush=True)
                if "CHAT_COMPARISON_KEYBOARD_VISIBLE" in line:
                    subprocess.run([adb, "-s", args.device, "shell", "input", "text", "Thanks"], check=True)
                    time.sleep(0.4)
                    with (output / "android-keyboard.png").open("wb") as png:
                        subprocess.run([adb, "-s", args.device, "exec-out", "screencap", "-p"], stdout=png, check=True)
                    action = ["tap", *map(str, args.ime_tap)] if args.ime_tap else ["keyevent", "66"]
                    subprocess.run([adb, "-s", args.device, "shell", "input", *action], check=True)
            if drive.wait():
                raise SystemExit(drive.returncode)


if __name__ == "__main__":
    main()
