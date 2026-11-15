import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[2] / "bootstrap/garage-init.sh"
MOCK = r'''#!/usr/bin/env python3
import base64, json, os, sys
from pathlib import Path
p = Path(os.environ["MOCK_STATE"])
s = json.loads(p.read_text())
a = sys.argv[1:]
fault = os.environ.get("MOCK_FAULT", "")
def save(): p.write_text(json.dumps(s))
def out(value):
    print(json.dumps(value) if isinstance(value, (dict, list)) else value)
    save()
    sys.exit(0)
def fail(message="transport unavailable"):
    print(message, file=sys.stderr)
    save()
    sys.exit(1)
if a[0] == "get":
    kind = a[1]
    if kind == "sts": out("3")
    if kind == "pod": out("host-" + a[4][-1])
    if kind == "pvc": out("1Gi")
    if kind == "secret":
        if fault == "secret": fail("Forbidden")
        if fault in ("missing-secret", "external"): out("")
        name = a[4]
        key = "worker" if name.endswith("reference") else "seed"
        out({"data": {"AWS_ACCESS_KEY_ID": base64.b64encode(("GK-"+key).encode()).decode(),
                      "AWS_SECRET_ACCESS_KEY": base64.b64encode(b"private-test-sentinel").decode()}})
    if kind == "externalsecret":
        if fault == "external": fail("Forbidden")
        out("externalsecret/pending")
    fail("unexpected get: " + repr(a))
if a[0] != "exec": fail("unexpected command: " + repr(a))
a = a[a.index("/garage")+1:]
# Do not record secret arguments, even in this test fixture.
s["calls"].append(a[:2])
if a[0] == "json-api":
    api = a[1]
    if api == "GetClusterStatus":
        s["status_calls"] += 1
        if fault == "membership" and s["status_calls"] == 3: fail()
        out({"nodes": [{"id": str(i), "hostname": "garage-node-"+str(i), "isUp": True} for i in range(3)]})
    if api == "GetClusterLayout": out({"roles": s["roles"], "stagedRoleChanges": s["staged"]})
    if api == "ListBuckets":
        if fault == "buckets": fail()
        out([{"globalAliases": ["claude-reference"]}] if s["bucket"] else [])
    if api == "ListKeys":
        if fault == "keys": fail()
        keys = [{"id": k["id"], "name": n} for n,k in s["keys"].items()]
        if fault == "duplicate": keys = [{"id": "a", "name": "claude-worker"}, {"id": "b", "name": "claude-worker"}]
        out(keys)
if a[:2] == ["layout", "assign"]:
    s["staged"].append({"id": a[-1]}); out("")
if a[:2] == ["layout", "show"]: out("garage layout apply --version 1")
if a[:2] == ["layout", "apply"]:
    if fault == "apply": fail()
    s["roles"] = s["staged"]; s["staged"] = []; out("")
if a[:2] == ["bucket", "create"]: s["bucket"] = True; out("")
if a[0] == "bucket" and a[1] in ("deny", "allow"): out("")
if a[:2] == ["key", "import"]:
    if fault == "import":
        print(a[-1]); fail("server echoed " + a[-1])
    s["keys"][a[4]] = {"id": a[5], "secret": a[6]}; out("")
if a[:2] == ["key", "create"]:
    s["keys"][a[2]] = {"id": "minted", "secret": "minted-sentinel"}; out("")
if a[:2] == ["key", "info"]:
    if fault == "key-info": fail()
    key = next((v for n,v in s["keys"].items() if n == a[2] or v["id"] == a[2]), None)
    if key is None: fail("missing key")
    out("Key ID: " + key["id"] + "\nSecret key: " + key["secret"])
fail("unexpected garage command: " + repr(a[:2]))
'''


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.directory = Path(self.tmp.name)
        self.state = self.directory / "state.json"
        self.state.write_text(json.dumps(dict(roles=[], staged=[], keys={}, bucket=False,
                                             calls=[], status_calls=0)))
        kubectl = self.directory / "kubectl"
        kubectl.write_text(MOCK)
        kubectl.chmod(0o755)

    def run_script(self, fault="", mint=False):
        env = {k: v for k, v in os.environ.items() if not k.startswith("GARAGE_")}
        env.update(PATH=str(self.directory)+os.pathsep+env["PATH"],
                   MOCK_STATE=str(self.state), MOCK_FAULT=fault)
        if mint:
            env.update(GARAGE_KEY_RO_SECRET="", GARAGE_KEY_RW_SECRET="")
        result = subprocess.run(["bash", str(SCRIPT)], env=env, text=True,
                                capture_output=True, timeout=15)
        self.assertNotIn("private-test-sentinel", result.stdout + result.stderr)
        return result

    def test_import_and_rerun(self):
        first = self.run_script()
        self.assertEqual(first.returncode, 0, first.stderr)
        again = self.run_script()
        self.assertEqual(again.returncode, 0, again.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(len(state["keys"]), 2)
        self.assertEqual(state["calls"].count(["layout", "apply"]), 1)
        self.assertEqual(state["calls"].count(["key", "import"]), 2)

    def test_resume_failed_apply(self):
        self.assertNotEqual(self.run_script("apply").returncode, 0)
        self.assertEqual(len(json.loads(self.state.read_text())["staged"]), 3)
        resumed = self.run_script()
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        state = json.loads(self.state.read_text())
        self.assertEqual(len(state["roles"]), 3)
        self.assertEqual(state["staged"], [])
        self.assertEqual(state["calls"].count(["layout", "assign"]), 3)

    def test_failed_membership_snapshot_never_assigns(self):
        self.assertNotEqual(self.run_script("membership").returncode, 0)
        self.assertNotIn(["layout", "assign"], json.loads(self.state.read_text())["calls"])

    def test_staged_lost_node_is_not_applied(self):
        state = json.loads(self.state.read_text())
        state["staged"] = [{"id": "orphaned-old-node", "zone": "lost-host", "capacity": 1073741824}]
        self.state.write_text(json.dumps(state))
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        state = json.loads(self.state.read_text())
        self.assertNotIn(["layout", "apply"], state["calls"])
        self.assertNotIn(["layout", "assign"], state["calls"])

    def test_failures_do_not_create_credentials(self):
        for fault in ("buckets", "keys", "duplicate", "secret", "missing-secret", "external", "import"):
            with self.subTest(fault=fault):
                result = self.run_script(fault)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                state = json.loads(self.state.read_text())
                self.assertEqual(state["keys"], {})
                self.assertNotIn(["key", "create"], state["calls"])

    def test_existing_secret_lookup_failure_is_fatal(self):
        self.assertEqual(self.run_script().returncode, 0)
        self.assertNotEqual(self.run_script("key-info").returncode, 0)

    def test_explicit_mint(self):
        result = self.run_script(mint=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(self.state.read_text())["keys"]), 2)
        self.assertIn("minted-sentinel", result.stdout)


if __name__ == "__main__":
    unittest.main()
