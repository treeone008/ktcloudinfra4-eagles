#!/usr/bin/env python3
"""
Heat webhook adapter

HEAT_SCALE_MODE=signal     → openstack stack resource signal (ASG / scale-test)
HEAT_SCALE_MODE=parameter  → openstack stack update --parameter worker_count=N
                             (고정 IP 템플릿 scale-cpu-test.yaml)

Kolla admin-openrc 사용 시: source ~/admin-service-openrc.sh 후 실행, OS_CLOUD unset 권장.
mgmt venv: export OPENSTACK_BIN=~/venv/bin/openstack
"""
import json
import os
import subprocess
import logging
import time
from flask import Flask, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

STACK = os.environ["HEAT_STACK"]
# unset이면 admin-openrc OS_* env 사용 (--os-cloud 안 붙임)
OS_CLOUD = os.environ.get("OS_CLOUD", "").strip()
OPENSTACK_BIN = os.environ.get("OPENSTACK_BIN", "openstack")
SCALE_MODE = os.environ.get("HEAT_SCALE_MODE", "signal")
WORKER_PARAM = os.environ.get("HEAT_WORKER_PARAM", "worker_count")
WORKER_MIN = int(os.environ.get("HEAT_WORKER_MIN", "0"))
WORKER_MAX = int(os.environ.get("HEAT_WORKER_MAX", "3"))
POLICY_UP = os.environ.get("POLICY_UP", "scale_up")
POLICY_DOWN = os.environ.get("POLICY_DOWN", "scale_down")
COOLDOWN = int(os.environ.get("HEAT_COOLDOWN", "180"))

_last_scale = 0.0


def _openstack_cmd(*args: str) -> list[str]:
    cmd = [OPENSTACK_BIN]
    if OS_CLOUD:
        cmd.extend(["--os-cloud", OS_CLOUD])
    cmd.extend(args)
    return cmd


def _run(cmd: list[str]) -> subprocess.CompletedProcess:
    app.logger.info("running: %s", " ".join(cmd))
    return subprocess.run(cmd, capture_output=True, text=True, check=False)


def _cooldown_ok() -> bool:
    global _last_scale
    now = time.time()
    if now - _last_scale < COOLDOWN:
        app.logger.warning("cooldown %ss — skip", COOLDOWN)
        return False
    _last_scale = now
    return True


def _to_int(value) -> int | None:
    if value is None:
        return None
    try:
        return int(str(value).strip().strip('"'))
    except (TypeError, ValueError):
        return None


def _parse_worker_count(stack_json: dict) -> int | None:
    """OpenStack CLI version may return parameters as dict, list, or nested."""
    params = stack_json.get("parameters")
    if params is None and isinstance(stack_json.get("stack"), dict):
        params = stack_json["stack"].get("parameters")

    if isinstance(params, dict):
        if WORKER_PARAM in params:
            return _to_int(params[WORKER_PARAM])
        for key, val in params.items():
            if str(key).endswith(WORKER_PARAM):
                return _to_int(val)
    elif isinstance(params, list):
        for p in params:
            if not isinstance(p, dict):
                continue
            key = p.get("parameter_key") or p.get("key") or p.get("name")
            if key == WORKER_PARAM:
                return _to_int(
                    p.get("parameter_value") or p.get("value") or p.get("val")
                )
    elif isinstance(params, str):
        # YAML-ish blob: "worker_count : 0"
        for line in params.splitlines():
            if WORKER_PARAM not in line:
                continue
            if ":" in line:
                return _to_int(line.split(":", 1)[1])
    return None


def _worker_count_from_value_column() -> int | None:
    """Fallback when JSON parameters shape differs."""
    result = _run(_openstack_cmd(
        "stack", "show", STACK, "-f", "value", "-c", "parameters",
    ))
    if result.returncode != 0:
        app.logger.error("stack show -c parameters failed: %s", result.stderr)
        return None
    return _parse_worker_count({"parameters": result.stdout.strip()})


def _current_worker_count() -> int | None:
    result = _run(_openstack_cmd("stack", "show", STACK, "-f", "json"))
    if result.returncode != 0:
        app.logger.error("stack show failed: %s", result.stderr)
        return _worker_count_from_value_column()

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        app.logger.error("stack show json decode failed: %s", result.stdout[:500])
        return _worker_count_from_value_column()

    count = _parse_worker_count(data)
    if count is None:
        app.logger.warning(
            "parameter %s not in json %r — trying value column",
            WORKER_PARAM,
            data.get("parameters"),
        )
        count = _worker_count_from_value_column()
    if count is None:
        app.logger.error("parameter %s not found", WORKER_PARAM)
    else:
        app.logger.info("current worker_count=%s", count)
    return count


def signal(policy: str):
    result = _run(_openstack_cmd(
        "stack", "resource", "signal", STACK, policy,
    ))
    if result.returncode != 0:
        app.logger.error("stderr: %s", result.stderr)
        return result.stderr or result.stdout, 500
    return "ok\n", 200


def scale_parameter(delta: int):
    current = _current_worker_count()
    if current is None:
        return "cannot read worker_count\n", 500

    new_count = max(WORKER_MIN, min(WORKER_MAX, current + delta))
    if new_count == current:
        return f"unchanged worker_count={current}\n", 200

    if not _cooldown_ok():
        return "cooldown\n", 429

    result = _run(_openstack_cmd(
        "stack", "update", "--existing", STACK,
        "--parameter", f"{WORKER_PARAM}={new_count}",
        "--wait",
    ))
    if result.returncode != 0:
        app.logger.error("stderr: %s", result.stderr)
        global _last_scale
        _last_scale = 0.0
        return result.stderr or result.stdout, 500
    return f"ok worker_count={new_count}\n", 200


@app.post("/scale/up")
def scale_up():
    app.logger.info("scale up webhook: %s", request.get_data(as_text=True)[:200])
    if SCALE_MODE == "parameter":
        body, code = scale_parameter(+1)
        return body, code
    body, code = signal(POLICY_UP)
    return body, code


@app.post("/scale/down")
def scale_down():
    app.logger.info("scale down webhook: %s", request.get_data(as_text=True)[:200])
    if SCALE_MODE == "parameter":
        body, code = scale_parameter(-1)
        return body, code
    body, code = signal(POLICY_DOWN)
    return body, code


@app.get("/health")
def health():
    return "ok\n", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
