import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

SCRIPT = Path(__file__).resolve().parents[1] / "k3s-memory.py"
spec = importlib.util.spec_from_file_location("k3s_memory", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MemoryConfigTests(unittest.TestCase):
    def test_preserves_config_and_non_memory_settings(self):
        config = {"node-ip": "192.0.2.1", "disable": ["traefik"],
                  "kubelet-arg": ["max-pods=80", "system-reserved=cpu=200m,memory=128Mi",
                                  "kube-reserved=pid=100,memory=256Mi",
                                  "eviction-hard=nodefs.available<7%,imagefs.available<8%"]}
        result = module.configure(config)
        self.assertEqual(result["node-ip"], "192.0.2.1")
        self.assertEqual(result["disable"], ["traefik"])
        args = dict(a.split("=", 1) for a in result["kubelet-arg"])
        self.assertEqual(args["max-pods"], "80")
        self.assertIn("cpu=200m", args["system-reserved"])
        self.assertIn("pid=100", args["kube-reserved"])
        self.assertIn("memory=512Mi", args["system-reserved"])
        self.assertIn("memory=1536Mi", args["kube-reserved"])
        self.assertIn("nodefs.available<7%", args["eviction-hard"])
        self.assertIn("imagefs.available<8%", args["eviction-hard"])
        self.assertIn("memory.available<512Mi", args["eviction-hard"])
        self.assertEqual(module.configure(result), result)

    def run_script(self, path, *args):
        return subprocess.run([sys.executable, str(SCRIPT), "--config", str(path), *args],
                              capture_output=True, text=True)

    def test_write_backup_idempotence_and_network_update(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            original = "node-ip: 192.0.2.1\nflannel-iface: eth0\ndisable: [traefik]\n"
            path.write_text(original)
            path.chmod(0o640)
            preview = self.run_script(path)
            self.assertEqual(preview.returncode, 0, preview.stderr)
            self.assertEqual(path.read_text(), original)
            update = self.run_script(path, "--write", "--node-ip", "192.0.2.2",
                                     "--flannel-iface", "bond0")
            self.assertEqual(update.returncode, 0, update.stderr)
            first = path.read_bytes()
            data = yaml.safe_load(first)
            self.assertEqual(data["flannel-iface"], "bond0")
            self.assertEqual(data["disable"], ["traefik"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o640)
            self.assertEqual(Path(str(path) + ".before-memory").read_text(), original)
            self.assertEqual(self.run_script(path, "--write").returncode, 0)
            self.assertEqual(path.read_bytes(), first)
            # Never silently discard the rollback snapshot on a later change.
            again = self.run_script(path, "--write", "--node-ip", "192.0.2.3",
                                    "--flannel-iface", "bond0")
            self.assertNotEqual(again.returncode, 0)
            self.assertEqual(path.read_bytes(), first)

    def test_ambiguous_input_never_changes_file(self):
        inputs = ["kubelet-arg: nope\n", "kubelet-arg: [config=/other]\n",
                  "kubelet-arg+: [max-pods=30]\n", "node-ip: a\nnode-ip: b\n",
                  "kubelet-arg: [system-reserved=memory=1Gi, system-reserved=cpu=1]\n"]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "config.yaml"
            for original in inputs:
                with self.subTest(original=original):
                    path.write_text(original)
                    self.assertNotEqual(self.run_script(path, "--write").returncode, 0)
                    self.assertEqual(path.read_text(), original)
                    self.assertFalse(Path(str(path) + ".before-memory").exists())
            path.write_text("node-ip: 192.0.2.1\n")
            dropins = Path(str(path) + ".d")
            dropins.mkdir()
            (dropins / "override.yaml").write_text("kubelet-arg: []\n")
            self.assertNotEqual(self.run_script(path, "--write").returncode, 0)
            self.assertEqual(path.read_text(), "node-ip: 192.0.2.1\n")


if __name__ == "__main__":
    unittest.main()
