"""Session lifecycle and mount boundary tests, without a host Podman engine."""

import concurrent.futures
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[5]
MODULE = ROOT / "src/python/uraj/contained_podman.py"
SPEC = importlib.util.spec_from_file_location("contained_podman", MODULE)
RUNTIME = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNTIME)


class Mounts(unittest.TestCase):
    def test_nested_readonly_order_and_spaces(self):
        with tempfile.TemporaryDirectory() as tmp:
            project = Path(tmp) / "project space"
            project.mkdir()
            protected = project / ".git"
            protected.mkdir()
            result = RUNTIME.session_mounts(
                ["--share=" + str(project), "--expose=" + str(protected)]
            )
            self.assertEqual(
                result,
                [
                    (project, str(project), "rw"),
                    (protected, str(protected), "ro"),
                ],
            )

    def test_mapped_mount_uses_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "instances"
            source.mkdir()
            target = tmp + "/work tree/instances"
            result = RUNTIME.session_mounts(
                [f"--share={source}={target}", f"--expose={source}={target}"]
            )
            self.assertEqual(
                result, [(source, target, "rw"), (source, target, "ro")]
            )
            for mapped in (
                f"{source}=relative",
                f"{source}=/run/x",
                f"{source}=/home/podman",
                f"{source}=/tmp/../etc",
                f"{source}=/tmp/a=b",
                f"{source}=/tmp/a:b",
                f"/etc={target}",
            ):
                with self.subTest(mapped=mapped), self.assertRaises(ValueError):
                    RUNTIME.session_mounts(["--share=" + mapped])

    def test_infrastructure_and_ambiguous_paths_rejected(self):
        for path in (
            "/",
            "/run",
            "/run/user/1000",
            "/home",
            "/etc",
            "/home/podman",
            "/tmp/a:b",
            "/tmp/a=b",
            "relative",
        ):
            with self.subTest(path=path), self.assertRaises(ValueError):
                RUNTIME.session_mounts(["--share=" + path])


class Session(unittest.TestCase):
    def exercise(self, fail_start=False, service=True):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            project = root / "project"
            project.mkdir()
            state = root / "state"
            state.mkdir(mode=0o700)
            socket = root / "run/host/podman.sock"
            if service:
                socket.parent.parent.mkdir(mode=0o700)
                socket.parent.mkdir(mode=0o700)
                socket.touch()
            calls = []

            class Manager:
                def __init__(self, *args):
                    calls.append(args[-1])
                    self.key = "fixture"
                    self.directory = state
                    self.run_directory = state

                def attach(self):
                    calls.append("attach")
                    if fail_start:
                        raise RuntimeError("injected startup failure")
                    return state / "api"

                def detach(self):
                    calls.append("detach")

            original_exists = Path.exists

            def exists(path):
                if str(path) in (
                    "/dev/fuse",
                    "/dev/net/tun",
                    "/sys/fs/cgroup/cgroup.controllers",
                ):
                    return True
                return original_exists(path)

            output = root / "agent-result.json"
            code = "import json,sys; json.dump(sys.argv[1:], open(sys.argv[1], 'w')); sys.exit(23)"
            command = [
                "session",
                "--podman=/fixture/podman",
                "--project=" + str(project),
                "--state-root=" + str(state),
                "--runtime-root=" + str(root / "run"),
                "--mount-option=--share=" + str(project),
                "--",
                sys.executable,
                "-c",
                code,
                str(output),
                "--expose=@CONTAINED_PODMAN_SOCKET@=/run/contained-agent/podman",
            ]
            with (
                mock.patch.object(sys, "argv", command),
                mock.patch.object(RUNTIME, "SharedRuntime", Manager),
                mock.patch.object(Path, "exists", exists),
            ):
                previous_umask = os.umask(0o077)
                try:
                    if not service:
                        with (
                            self.assertRaises(SystemExit),
                            mock.patch("sys.stderr", io.StringIO()) as error,
                        ):
                            RUNTIME.session_main()
                        self.assertIn("podman-service", error.getvalue())
                        self.assertEqual(calls, [])
                        return
                    status = RUNTIME.session_main()
                finally:
                    os.umask(previous_umask)
            self.assertEqual(
                calls, ["unix://" + str(socket), "attach", "detach"]
            )
            if fail_start:
                self.assertEqual(status, 1)
                self.assertFalse(output.exists())
            else:
                self.assertEqual(status, 23)
                argv = json.loads(output.read_text())
                self.assertEqual(
                    argv[-1],
                    "--expose="
                    + str(state / "api")
                    + "=/run/contained-agent/podman",
                )

    def test_exit_code_socket_mapping_and_detach(self):
        self.exercise()

    def test_requires_host_service(self):
        self.exercise(service=False)

    def test_detach_after_startup_failure(self):
        self.exercise(fail_start=True)

    def test_image_mismatch_stops_before_container_execution(self):
        for cached in (False, True):
            with (
                self.subTest(cached=cached),
                tempfile.TemporaryDirectory() as tmp,
            ):
                engine = RUNTIME.Experiment(
                    Path(tmp),
                    "/fixture/podman",
                    "image",
                    "",
                    "nested",
                    expected_image="expected",
                )
                self.addCleanup(engine.log.close)
                responses = [
                    subprocess.CompletedProcess(
                        [],
                        0,
                        json.dumps(
                            {
                                "host": {"security": {"rootless": True}},
                                "store": {"graphDriverName": "overlay"},
                            }
                        ),
                        "",
                    ),
                    subprocess.CompletedProcess([], 0 if cached else 1, "", ""),
                ]
                if not cached:
                    responses.append(subprocess.CompletedProcess([], 0, "", ""))
                responses.append(
                    subprocess.CompletedProcess([], 0, "unexpected\n", "")
                )
                with mock.patch.object(
                    engine, "run", side_effect=responses
                ) as run:
                    with self.assertRaisesRegex(
                        RuntimeError, "Runtime image changed"
                    ):
                        engine.start()
                    self.assertEqual(run.call_count, 3 if cached else 4)
                    commands = [call.args[0][2] for call in run.call_args_list]
                    self.assertEqual("pull" in commands, not cached)
                    self.assertNotIn("run", commands)
                    self.assertFalse(engine.started)

    def test_storage_driver_is_configured_and_verified(self):
        for driver in ("overlay", "vfs"):
            with (
                self.subTest(driver=driver),
                tempfile.TemporaryDirectory() as tmp,
            ):
                engine = RUNTIME.Experiment(
                    Path(tmp),
                    "/fixture/podman",
                    "image",
                    "",
                    "nested",
                    storage_driver=driver,
                )
                self.addCleanup(engine.log.close)
                engine.prepare()
                for name in ("storage.conf", "inner-storage.conf"):
                    self.assertIn(
                        f'driver="{driver}"\n',
                        (Path(tmp) / name).read_text(),
                    )
                other = "vfs" if driver == "overlay" else "overlay"
                info = {"store": {"graphDriverName": other}}
                with self.assertRaisesRegex(RuntimeError, "storage driver"):
                    engine.check_driver("inner", info)
                info["store"]["graphDriverName"] = driver
                engine.check_driver("inner", info)
                self.assertEqual(engine.results["inner_storage_driver"], driver)

    def test_remote_outer_engine_has_no_local_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            engine = RUNTIME.Experiment(
                Path(tmp),
                "/fixture/podman",
                "image",
                "",
                "nested",
                delegate_cgroup=True,
                mounts=[],
                persistent=True,
                outer_url="unix:///fixture/host.sock",
            )
            self.addCleanup(engine.log.close)
            engine.prepare()
            for name in ("containers.conf", "storage.conf", "shared"):
                self.assertFalse((Path(tmp) / name).exists(), name)
            self.assertTrue((Path(tmp) / "inner-storage.conf").exists())
            self.assertNotIn("CONTAINERS_CONF", engine.env)
            self.assertNotIn("CONTAINERS_STORAGE_CONF", engine.env)


class SharedRuntime(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        self.spec = RUNTIME.runtime_spec(
            self.project,
            [(self.project, str(self.project), "rw")],
            "a" * 64,
            "/fixture/podman",
        )
        self.running = False
        self.starts = 0
        self.cleanups = []
        self.fail_start = False
        self.tasks = ""
        owner = self

        class Engine:
            local = ["local"]
            remote = ["remote"]
            name = "contained-agent-runtime-fixture"

            def __init__(self):
                self.log = io.StringIO()

            def prepare(self):
                pass

            def start(self):
                owner.starts += 1
                if owner.fail_start:
                    raise RuntimeError("injected failure")
                owner.running = True

            def cleanup(self, preserve_storage=False):
                owner.cleanups.append(preserve_storage)
                owner.running = False

            def run(self, command, **kwargs):
                if command[0] == "local":
                    value = [
                        {
                            "State": {"Running": owner.running},
                            "Image": owner.spec["image"],
                        }
                    ]
                elif "ps" in command:
                    return subprocess.CompletedProcess(
                        command, 0, owner.tasks, ""
                    )
                else:
                    value = {"host": {"security": {"rootless": True}}}
                return subprocess.CompletedProcess(
                    command, 0, json.dumps(value), ""
                )

        self.patch = mock.patch.object(
            RUNTIME.SharedRuntime, "engine", side_effect=Engine
        )
        self.patch.start()
        self.addCleanup(self.patch.stop)

    def manager(self):
        result = RUNTIME.SharedRuntime(
            self.root / "state",
            self.root / "run",
            self.spec,
            "image",
            "unix:///fixture/host.sock",
        )
        self.addCleanup(result.detach)
        return result

    def test_concurrent_sessions_start_once_and_prevent_stop(self):
        first, second, stopper = (self.manager() for _ in range(3))
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            sockets = list(
                pool.map(lambda manager: manager.attach(), [first, second])
            )
        self.assertEqual(sockets[0], sockets[1])
        self.assertEqual(self.starts, 1)
        with self.assertRaisesRegex(RuntimeError, "active sessions"):
            stopper.stop()
        first.detach()
        with self.assertRaisesRegex(RuntimeError, "active sessions"):
            stopper.stop()
        second.detach()
        self.assertTrue(self.running)
        stopper.stop()
        self.assertFalse(self.running)
        self.assertTrue(all(self.cleanups))

    def test_idle_stop_waits_for_grace_sessions_and_tasks(self):
        manager = self.manager()
        self.assertFalse(manager.stop_if_idle(0))  # never started
        manager.attach()
        self.assertFalse(self.manager().stop_if_idle(0))  # live session
        manager.detach()
        self.assertTrue((manager.directory / "last-detach").exists())
        self.assertFalse(self.manager().stop_if_idle(3600))
        self.tasks = "0123456789ab\n"
        self.assertFalse(self.manager().stop_if_idle(0))
        self.assertTrue(self.running)
        self.tasks = ""
        cleanups = len(self.cleanups)
        old = 1_000_000
        for name in ("ready.json", "last-detach"):
            os.utime(manager.directory / name, (old, old))
        self.assertTrue(self.manager().stop_if_idle(60))
        self.assertFalse(self.running)
        self.assertEqual(self.cleanups[cleanups:], [True])

    def test_collect_idle_stops_only_current_runtimes(self):
        manager = self.manager()
        manager.attach()
        manager.detach()
        state = self.root / "state"
        (state / "host").mkdir()
        stale = state / ("b" * 32)
        stale.mkdir()
        (stale / "spec.json").write_text(json.dumps({"schema": 2}))
        with mock.patch("sys.stdout", io.StringIO()) as output:
            RUNTIME.collect_idle(
                state, self.root / "run", "unix:///fixture/host.sock", 0
            )
        self.assertFalse(self.running)
        self.assertIn(manager.key, output.getvalue())
        self.assertNotIn("b" * 32, output.getvalue())

    def test_boot_change_restarts_but_same_boot_reuses(self):
        first = self.manager()
        first.attach()
        first.detach()
        second = self.manager()
        second.attach()
        second.detach()
        self.assertEqual(self.starts, 1)
        second.boot = "next-boot"
        second.attach()
        self.assertEqual(self.starts, 2)
        self.assertTrue(all(self.cleanups))

    def test_unhealthy_runtime_cannot_restart_with_live_session(self):
        first, second = self.manager(), self.manager()
        first.attach()
        self.running = False
        with self.assertRaisesRegex(RuntimeError, "other sessions"):
            second.attach()
        self.assertEqual(self.starts, 1)
        first.detach()
        second.attach()
        self.assertEqual(self.starts, 2)

    def test_timeout_does_not_restart_active_runtime(self):
        first, second = self.manager(), self.manager()
        first.attach()
        with mock.patch.object(
            second, "healthy", side_effect=subprocess.TimeoutExpired("info", 15)
        ):
            with self.assertRaisesRegex(RuntimeError, "other sessions"):
                second.attach()
            first.detach()
            second.attach()
        self.assertEqual(self.starts, 2)

    def test_failed_start_can_be_retried(self):
        manager = self.manager()
        self.fail_start = True
        with self.assertRaisesRegex(RuntimeError, "injected failure"):
            manager.attach()
        self.assertIsNone(manager.lease)
        self.assertFalse((manager.directory / "ready.json").exists())
        self.fail_start = False
        manager.attach()
        self.assertEqual(self.starts, 2)

    def test_identity_includes_mount_permissions_and_inode(self):
        original = RUNTIME.runtime_key(self.spec)
        readonly = RUNTIME.runtime_spec(
            self.project,
            [(self.project, str(self.project), "ro")],
            "a" * 64,
            "/fixture/podman",
        )
        self.assertNotEqual(original, RUNTIME.runtime_key(readonly))
        self.project.rename(self.root / "old-project")
        self.project.mkdir()
        replaced = RUNTIME.runtime_spec(
            self.project,
            [(self.project, str(self.project), "rw")],
            "a" * 64,
            "/fixture/podman",
        )
        self.assertNotEqual(original, RUNTIME.runtime_key(replaced))

    def test_identity_includes_storage_driver(self):
        self.assertEqual(self.spec["storage_driver"], "overlay")
        vfs = RUNTIME.runtime_spec(
            self.project,
            [(self.project, str(self.project), "rw")],
            "a" * 64,
            "/fixture/podman",
            "vfs",
        )
        self.assertNotEqual(
            RUNTIME.runtime_key(self.spec), RUNTIME.runtime_key(vfs)
        )

    def test_cleanup_preserves_graphroots_and_home(self):
        state, run = self.root / "state", self.root / "run"
        state.mkdir()
        run.mkdir()
        engine = RUNTIME.Experiment(
            state,
            "podman",
            "image",
            "",
            "nested",
            run_directory=run,
            persistent=True,
        )
        self.addCleanup(engine.log.close)
        with mock.patch.object(engine, "run") as command:
            command.return_value = subprocess.CompletedProcess([], 0, "", "")
            engine.cleanup(preserve_storage=True)
        argv = command.call_args.args[0]
        self.assertEqual(
            argv[6:],
            [
                str(run / "run/netns"),
                str(run / "inner-run"),
                str(run / "outer-run"),
                str(run / "run"),
                str(run / "api"),
            ],
        )
        for name in ("inner", "outer-storage", "home"):
            self.assertNotIn(str(state / name), argv)


class RemoteCleanup(unittest.TestCase):
    def test_subordinate_files_are_removed_by_runtime_task(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            plain, owned = root / "plain", root / "inner-run"
            for path in (plain, owned):
                (path / "nested").mkdir(parents=True)
            engine = RUNTIME.Experiment(
                root,
                "/fixture/podman",
                "image",
                "",
                "nested",
                expected_image="f" * 64,
                outer_url="unix:///fixture/host.sock",
            )
            self.addCleanup(engine.log.close)
            real = RUNTIME.shutil.rmtree
            denied = []

            def rmtree(path):
                # The first attempt on OWNED fails as for subordinate IDs.
                if Path(path) == owned and not denied:
                    denied.append(path)
                    raise PermissionError(13, "denied", str(path))
                real(path)

            with (
                mock.patch.object(RUNTIME.shutil, "rmtree", rmtree),
                mock.patch.object(engine, "run") as run,
            ):
                run.return_value = subprocess.CompletedProcess([], 0, "", "")
                engine.remove_through_runtime(
                    [str(plain), str(owned), str(root / "missing")]
                )
            argv = run.call_args.args[0]
            self.assertEqual(
                argv[:4],
                [
                    "/fixture/podman",
                    "--remote",
                    "--url",
                    "unix:///fixture/host.sock",
                ],
            )
            self.assertIn(f"{owned}:/cleanup/0:rw", argv)
            self.assertNotIn(f"{plain}:/cleanup/0:rw", argv)
            self.assertIn("--userns=keep-id:uid=1000,gid=1000", argv)
            self.assertIn("f" * 64, argv)
            self.assertFalse(plain.exists())
            self.assertFalse(owned.exists())


class HostService(unittest.TestCase):
    def test_private_engine_configuration_and_clean_stop(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            record = root / "podman.json"
            fake = root / "podman"
            fake.write_text(
                "#!" + sys.executable + "\n"
                "import json, os, pathlib, sys, time\n"
                f"json.dump([sys.argv[1:], dict(os.environ)], open({str(record)!r}, 'w'))\n"
                "pathlib.Path(sys.argv[-1].removeprefix('unix://')).touch()\n"
                "time.sleep(60)\n"
            )
            fake.chmod(0o755)
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(MODULE),
                    "--session",
                    "--host-service",
                    "--podman",
                    str(fake),
                    "--state-root",
                    str(root / "state"),
                    "--runtime-root",
                    str(root / "run"),
                    "--collect-interval",
                    "0.1",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            socket = root / "run/host/podman.sock"
            for _ in range(100):
                if socket.exists() and record.exists():
                    break
                time.sleep(0.05)
            time.sleep(1.5)  # at least one idle collection pass
            process.terminate()
            stdout, stderr = process.communicate(timeout=40)
            self.assertEqual(process.returncode, 0, stderr)
            self.assertNotIn("Idle check failed", stdout)
            argv, env = json.loads(record.read_text())
            self.assertEqual(
                argv,
                [
                    "--remote=false",
                    "system",
                    "service",
                    "--time=0",
                    "unix://" + str(socket),
                ],
            )
            state = root / "state/host"
            self.assertEqual(env["HOME"], str(state / "home"))
            self.assertEqual(env["XDG_RUNTIME_DIR"], str(root / "run/host/xdg"))
            self.assertTrue(env["PATH"].startswith("/run/privileged/bin:"))
            storage = Path(env["CONTAINERS_STORAGE_CONF"]).read_text()
            self.assertIn('driver="overlay"', storage)
            self.assertIn(str(state / "storage"), storage)
            self.assertEqual(Path(env["CONTAINERS_CONF"]).parent, state)


class CleanupScript(unittest.TestCase):
    @unittest.skipUnless(shutil.which("unshare"), "needs unshare")
    def test_unmounts_overlay_home_before_removal(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            netns = root / "run/netns"
            netns.mkdir(parents=True)
            home = root / "outer storage/overlay"
            (home / "l").mkdir(parents=True)
            script = root / "cleanup.py"
            script.write_text(RUNTIME._CLEANUP_STORAGE)
            # Mirror the overlay driver's private self-bind, plus a nested
            # mount, in a throwaway user/mount namespace.
            result = subprocess.run(
                [
                    "unshare",
                    "-rm",
                    "sh",
                    "-ec",
                    'mount --bind "$1" "$1"; mount --make-private "$1"; '
                    'mount --bind "$1/l" "$1/l"; shift; exec "$@"',
                    "sh",
                    str(home),
                    sys.executable,
                    str(script),
                    str(netns),
                    str(root / "run"),
                    str(root / "outer storage"),
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            if "Operation not permitted" in result.stderr:
                self.skipTest("user namespaces unavailable")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse((root / "run").exists())
            self.assertFalse((root / "outer storage").exists())


if __name__ == "__main__":
    unittest.main()
