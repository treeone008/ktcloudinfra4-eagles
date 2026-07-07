#!/usr/bin/env python3
"""
Heat webhook adapter

HEAT_SCALE_MODE=signal     → openstack stack resource signal (ASG / scale-test)
HEAT_SCALE_MODE=parameter  → openstack stack update --parameter worker_count=N
                             (고정 IP 템플릿 scale-cpu-test.yaml)
"""
import os
import subprocess
import logging
import time
from flask import Flask, request

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)

STACK = os.environ["HEAT_STACK"]
OS_CLOUD = os.environ.get("OS_CLOUD", "openstack")
SCALE_MODE = os.environ.get("HEAT_SCALE_MODE", "signal")
WORKER_PARAM = os.environ.get("HEAT_WORKER_PARAM", "worker_count")
WORKER_MIN = int(os.environ.get("HEAT_WORKER_MIN", "1"))
WORKER_MAX = int(os.environ.get("HEAT_WORKER_MAX", "6"))
POLICY_UP = os.environ.get("POLICY_UP", "scale_up")
POLICY_DOWN = os.environ.get("POLICY_DOWN", "scale_down")
COOLDOWN = int(os.environ.get("HEAT_COOLDOWN", "180"))

_last_scale = 0.0


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


def signal(policy: str):
    result = _run([
        "openstack", "--os-cloud", OS_CLOUD,
        "stack", "resource", "signal", STACK, policy,
    ])
    if result.returncode != 0:
        app.logger.error("stderr: %s", result.stderr)
        return result.stderr or result.stdout, 500
    return "ok\n", 200


def _parse_worker_count(stack_json: dict) -> int | None:
    """OpenStack CLI version may return parameters as dict or list."""
    params = stack_json.get("parameters")
    if isinstance(params, dict):
        if WORKER_PARAM in params:
            return int(params[WORKER_PARAM])
    elif isinstance(params, list):
        for p in params:
            if isinstance(p, dict) and p.get("parameter_key") == WORKER_PARAM:
                return int(p.get("parameter_value"))
    return None


def _current_worker_count() -> int | None:
    result = _run([
        "openstack", "--os-cloud", OS_CLOUD,
        "stack", "show", STACK,
        "-f", "json",
    ])
    if result.returncode != 0:
        app.logger.error("stack show failed: %s", result.stderr)
        return None
    import json
    data = json.loads(result.stdout)
    count = _parse_worker_count(data)
    if count is None:
        app.logger.error("parameter %s not found in %r", WORKER_PARAM, data.get("parameters"))
    return count


def scale_parameter(delta: int):
    current = _current_worker_count()
    if current is None:
        return "cannot read worker_count\n", 500

    new_count = max(WORKER_MIN, min(WORKER_MAX, current + delta))
    if new_count == current:
        return f"unchanged worker_count={current}\n", 200

    if not _cooldown_ok():
        return "cooldown\n", 429

    result = _run([
        "openstack", "--os-cloud", OS_CLOUD,
        "stack", "update", "--existing", STACK,
        "--parameter", f"{WORKER_PARAM}={new_count}",
        "--wait",
    ])
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
