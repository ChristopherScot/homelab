#!/usr/bin/env python3
"""Preserve K3s configuration while reserving memory; never restart the service.

Requires python3-yaml (Ubuntu: apt-get install python3-yaml).
Run with --write on a host, or render a candidate without changing the file.
"""

import argparse
import os
from pathlib import Path
import re
import shutil
import tempfile

import yaml


class UniqueLoader(yaml.SafeLoader):
    pass


def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in result:
            raise ValueError(f"duplicate YAML key: {key}")
        result[key] = loader.construct_object(value_node)
    return result


UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)


def configure(config, node_ip=None, iface=None):
    if not isinstance(config, dict):
        raise ValueError("K3s configuration must be a mapping")
    if "kubelet-arg+" in config:
        raise ValueError("consolidate kubelet-arg+ into kubelet-arg first")
    args = config.get("kubelet-arg", [])
    if not isinstance(args, list) or not all(isinstance(a, str) for a in args):
        raise ValueError("kubelet-arg must be a list of strings")
    managed = {"system-reserved": {"memory": "512Mi"},
               "kube-reserved": {"memory": "1536Mi"},
               "eviction-hard": {"memory.available": "512Mi",
                                 "nodefs.available": "5%", "imagefs.available": "5%",
                                 "nodefs.inodesFree": "5%", "imagefs.inodesFree": "5%"}}
    kept = []
    seen = set()
    for arg in args:
        key, sep, value = arg.removeprefix("--").partition("=")
        if key in ("config", "config-dir"):
            raise ValueError("consolidate external kubelet configuration first")
        if key not in managed:
            kept.append(arg)
            continue
        if key in seen or not sep:
            raise ValueError(f"ambiguous kubelet argument: {key}")
        seen.add(key)
        # Preserve CPU/PID reservations and explicitly configured disk signals.
        for item in value.split(","):
            pair = re.fullmatch(r"([^=<]+)[=<]([^=<]+)", item)
            if not pair:
                raise ValueError(f"invalid {key} setting")
            signal, threshold = pair.groups()
            if signal not in ("memory", "memory.available"):
                managed[key][signal] = threshold
    for key, values in managed.items():
        operator = "<" if key == "eviction-hard" else "="
        kept.append(key + "=" + ",".join(k + operator + v for k, v in values.items()))
    config["kubelet-arg"] = kept
    if node_ip:
        config.update({"node-ip": node_ip, "flannel-iface": iface,
                       "write-kubeconfig-mode": "0644"})
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=Path("/etc/rancher/k3s/config.yaml"))
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--node-ip")
    parser.add_argument("--flannel-iface")
    options = parser.parse_args()
    if bool(options.node_ip) != bool(options.flannel_iface):
        parser.error("--node-ip and --flannel-iface must be supplied together")
    path = options.config
    try:
        # Later files can replace kubelet-arg, silently defeating this policy.
        if any(Path(str(path) + ".d").glob("*.yaml")):
            raise ValueError("consolidate config.yaml.d overrides before applying")
        if path.is_symlink():
            raise ValueError("refusing to replace a symlink")
        old = path.read_text() if path.exists() else ""
        config = yaml.load(old, Loader=UniqueLoader) if old.strip() else {}
        rendered = yaml.safe_dump(configure(config, options.node_ip, options.flannel_iface),
                                  sort_keys=False)
        if not options.write:
            print(rendered, end="")
            return
        if old == rendered:
            print("K3s memory configuration already current; service not restarted.")
            return
        backup = Path(str(path) + ".before-memory")
        if path.exists() and backup.exists():
            raise ValueError(f"backup already exists: {backup}; archive it before another change")
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            shutil.copy2(path, backup)
        fd, temporary = tempfile.mkstemp(prefix=".k3s-config-", dir=path.parent)
        try:
            with os.fdopen(fd, "w") as output:
                output.write(rendered)
                output.flush()
                os.fsync(output.fileno())
            if path.exists():
                stat = path.stat()
                os.chmod(temporary, stat.st_mode & 0o777)
                os.chown(temporary, stat.st_uid, stat.st_gid)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
        print("K3s configuration updated; service NOT restarted. Follow bootstrap/MEMORY.md.")
    except (ValueError, OSError, yaml.YAMLError) as error:
        parser.exit(1, f"ERROR: {error}\n")


if __name__ == "__main__":
    main()
