"""Initialize persistent configuration, then run the upstream HTTP server."""

import os
import secrets
import sys
from pathlib import Path


def configure(config, first_boot):
    if first_boot:
        config.conf = config.conf.updated(
            {
                "device": {
                    "preset_id": "linux.redroid",
                    "last_serial": "10.203.0.2:5555",
                    "adb_path": "/usr/bin/adb",
                    "game_package": "com.hypergryph.arknights",
                    "screenshot_backend": "adb_gzip",
                    "touch_backend": "maatouch",
                },
                "stage_plan_runner": "mower",
                # Enable only after setting a plan, threshold and Skland login.
                "stage_plan_enable": False,
                "maa_eat_stone": False,
            }
        )
    # Paths belong to the image; choices made in the WebUI persist.
    config.conf.maa_path = "/opt/maa"
    # Assign the parent too: upstream saves with exclude_unset=True.
    config.conf.webview = config.conf.webview.model_copy(
        update={
            "port": 58000,
            "tray": False,
            "token": config.conf.webview.token or secrets.token_urlsafe(32),
        }
    )
    config.save_conf()


def main():
    data = Path(os.environ["MOWER_DATA_DIR"])
    data.mkdir(parents=True, exist_ok=True)
    (data / "maa-cache").mkdir(exist_ok=True)
    first_boot = not any(
        (data / name).exists() for name in ("config/conf.yml", "conf.yml")
    )
    # Importing config creates/migrates files, so inspect first_boot first.
    from arknights_mower.utils import config  # noqa: PLC0415

    configure(config, first_boot)
    # Flask's entrypoint registers upstream's shutdown lifecycle. It starts
    # only the WebUI, not the game worker. No tokens are printed to logs.
    os.execv(
        sys.executable,
        [
            sys.executable,
            "-m",
            "flask",
            "--app",
            "server:app",
            "run",
            "--host=0.0.0.0",
            "--port=58000",
            "--no-reload",
        ],
    )


if __name__ == "__main__":
    main()
