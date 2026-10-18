"""Validate initialization with a supplied pinned Mower source tree."""

import importlib.util
import pathlib
import sys
import types


def main():
    source = pathlib.Path(sys.argv[1]).resolve()
    sys.path.insert(0, str(source))
    # Load real Pydantic models without config/__init__.py's disk writes.
    package = types.ModuleType("arknights_mower.utils.config")
    package.__path__ = [str(source / "arknights_mower/utils/config")]
    sys.modules[package.__name__] = package
    from arknights_mower.utils.config.conf import Conf  # noqa: PLC0415

    bootstrap_path = (
        pathlib.Path(__file__).resolve().parents[2] / "env/mower/bootstrap.py"
    )
    spec = importlib.util.spec_from_file_location("bootstrap", bootstrap_path)
    bootstrap = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(bootstrap)
    saved = []
    config = types.SimpleNamespace(conf=Conf(device={}))
    config.save_conf = lambda: saved.append(
        config.conf.model_dump(exclude_unset=True)
    )
    bootstrap.configure(config, first_boot=True)
    conf = Conf(**saved[-1])
    assert conf.device.last_serial == "10.203.0.2:5555"
    assert conf.device.preset_id == "linux.redroid"
    assert conf.device.game_package_confirmed
    assert conf.device.adb_path == "/usr/bin/adb"
    assert conf.adb == conf.device.last_serial
    assert conf.stage_plan_runner == "mower"
    assert not conf.stage_plan_enable
    assert not conf.maa_eat_stone
    assert len(conf.webview.token) >= 32
    token = conf.webview.token
    config.conf = conf.updated({"stage_plan_enable": True, "maa_gap": 2.5})
    bootstrap.configure(config, first_boot=False)
    restored = Conf(**saved[-1])
    assert restored.webview.token == token
    assert restored.stage_plan_enable
    assert restored.maa_gap == 2.5
    # Migration from an existing config with an unset webview parent.
    config.conf = Conf(device={})
    bootstrap.configure(config, first_boot=False)
    assert saved[-1]["webview"]["token"]
    print("Pinned Mower configuration initialization and preservation passed")


if __name__ == "__main__":
    main()
