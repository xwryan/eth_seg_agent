#!/usr/bin/env python3
"""SHM 联仿回归：用 SimFlow 跑两个 eth_seg_agent 节点的背靠背 BIDIR cosim。

先编译并跑通过用例 eth_shm_pair（两节点日志都须零 UVM_ERROR/FATAL 且有完成标记），再跑带内握手用例
eth_shm_hs_pair（两节点另须打印 ETH_SHM_HS_PASS）；再复用同一 simv 跑四个预期失败的用例（三个故障注入与
一个握手超时），要求 SimFlow 判失败且对应节点日志出现诊断，握手超时期间本端仿真时间只推进很少；
最后不经 SimFlow 直接跑三次 simv，确认错误配置在构建期即 fail closed。
环境变量：SIMFLOW_ROOT（含 simflow 包的目录）、SHM_WORK_ROOT、AIP_CORE_ROOT、NET_PACKET_ROOT、FLOW_CONTROL_ROOT、
ETH_SHM_WORK（产物目录），可选 SHM_SWITCH_BIN（缺省 $SHM_WORK_ROOT/shm_switch/shm_switch）。
"""
import os
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
PROJECT = ROOT / "test" / "shm" / "base.prj.yaml"
CHECK_LOG = ROOT / "scripts" / "check_log.py"
MARKER = "ETH_SHM_COSIM_TEST_COMPLETE"
HS_MARKER = "ETH_SHM_HS_PASS"
HS_TIMEOUT = "ERROR: eth_shm_wait: no 'hello' signal from the peer within 3000 ms"
# 握手超时期间本端仿真时间推进的上限（ns）：每次轮询只推进 shm_wait_poll_ns（缺省 1ns）。
HS_MAX_ADVANCE_NS = 100000
# 预期失败的用例：失败节点与其日志中必须出现的诊断。
RED_CASES = (
    ("eth_shm_pair_drop", "dut_b", "peer frame #5"),
    ("eth_shm_pair_corrupt", "dut_b", "peer frame #5: byte 20"),
    ("eth_shm_pair_overflow", "dut_b", "decoded source FIFO is full"),
    ("eth_shm_hs_no_signal", "dut_a", HS_TIMEOUT),
)
# 单进程错误配置：不启动 switch，agent/链路构建期即 fatal。
CONFIG_CASES = (
    (("+lb0_mac.shm=1",), "lb0_mac.shm=1 requires +SHM_ENABLE=1"),
    (("+lb0_mac.shm=1", "+lb0_mac.loopback=1"), "loopback and shm are mutually exclusive"),
    (("+lb0_client.shm=1",), "shm requires role ETH_SEG_MAC and is_active UVM_ACTIVE"),
)


def required_dir(name):
    value = os.environ.get(name, "")
    path = pathlib.Path(value).resolve() if value else None
    if path is None or not path.is_dir():
        raise SystemExit(f"{name} must name an existing directory (got {value!r})")
    return path


def run_case(env, simflow_root, work, case, compile_first):
    case_root = work / "sim" / "cosim" / case
    before = set(case_root.iterdir()) if case_root.is_dir() else set()
    command = [sys.executable, "-m", "simflow", "run", "--project", str(PROJECT),
               "--yaml", "eth_shm_cases", "--tc", case]
    if compile_first:
        command.append("-cmp")
    completed = subprocess.run(command, cwd=simflow_root, env=env, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, check=False)
    console = work / f"{case}.console.log"
    console.write_text(completed.stdout, encoding="utf-8")
    after = set(case_root.iterdir()) if case_root.is_dir() else set()
    runs = sorted(after - before)
    if len(runs) != 1:
        raise SystemExit(f"{case}: expected one new run directory under {case_root}, got {runs}; see {console}")
    logs = {}
    for log in sorted((runs[0] / "log").glob("*.log")):
        if log.name != "shm_switch.log":
            logs[log] = log.read_text(errors="replace")
    return completed.returncode, runs[0], logs, console


def node_log(logs, node):
    # 节点日志名含 testcase、端口与 seed；SimFlow 的 history 记录节点到日志的对应，这里按端口区分。
    port = {"dut_a": 0, "dut_b": 1}[node]
    matches = [path for path in logs if f"_port{port}_" in path.name]
    if len(matches) != 1:
        raise SystemExit(f"cannot find the {node} log among {[p.name for p in logs]}")
    return matches[0]


def main():
    simflow_root = required_dir("SIMFLOW_ROOT")
    shm_root = required_dir("SHM_WORK_ROOT")
    aip_root = required_dir("AIP_CORE_ROOT")
    net_root = required_dir("NET_PACKET_ROOT")
    flow_root = required_dir("FLOW_CONTROL_ROOT")
    work = pathlib.Path(os.environ.get("ETH_SHM_WORK", "")).resolve()
    if not os.environ.get("ETH_SHM_WORK"):
        raise SystemExit("ETH_SHM_WORK must name the output directory")
    switch = pathlib.Path(os.environ.get("SHM_SWITCH_BIN", shm_root / "shm_switch" / "shm_switch"))
    for path in (simflow_root / "simflow" / "__init__.py", switch,
                 shm_root / "shm_switch" / "files" / "shm_base.f",
                 aip_root / "aip_core.f", aip_root / "dist" / "lib" / "libaip_tcl_bridge.so",
                 net_root / "net_packet.f", flow_root / "flow_control.f"):
        if not path.is_file():
            raise SystemExit(f"missing prerequisite: {path}")
    work.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, ETH_SEG_AGENT_ROOT=str(ROOT), ETH_SHM_WORK=str(work), SHM_WORK_ROOT=str(shm_root),
               AIP_CORE_ROOT=str(aip_root), NET_PACKET_ROOT=str(net_root), FLOW_CONTROL_ROOT=str(flow_root),
               SHM_SWITCH_BIN=str(switch.resolve()))

    rc, run_dir, logs, console = run_case(env, simflow_root, work, "eth_shm_pair", True)
    if rc != 0:
        raise SystemExit(f"eth_shm_pair failed (rc={rc}); see {console} and {run_dir}")
    for node in ("dut_a", "dut_b"):
        log = node_log(logs, node)
        subprocess.run([sys.executable, str(CHECK_LOG), str(log), "run", MARKER], check=True)
        summary = [line for line in logs[log].splitlines() if f"[{MARKER}]" in line]
        print(f"{node}: {summary[0].split(f'[{MARKER}] ', 1)[1]}")
    print(f"PASS eth_shm_pair: {run_dir}")

    rc, run_dir, logs, console = run_case(env, simflow_root, work, "eth_shm_hs_pair", False)
    if rc != 0:
        raise SystemExit(f"eth_shm_hs_pair failed (rc={rc}); see {console} and {run_dir}")
    for node in ("dut_a", "dut_b"):
        log = node_log(logs, node)
        subprocess.run([sys.executable, str(CHECK_LOG), str(log), "run", MARKER], check=True)
        if not any(line.startswith(HS_MARKER + " ") for line in logs[log].splitlines()):
            raise SystemExit(f"eth_shm_hs_pair: {node} log lacks {HS_MARKER}; see {log}")
        summary = [line for line in logs[log].splitlines() if f"[{MARKER}]" in line]
        print(f"{node}: {summary[0].split(f'[{MARKER}] ', 1)[1]}")
    print(f"PASS eth_shm_hs_pair: {run_dir}")

    for case, node, expected in RED_CASES:
        rc, run_dir, logs, console = run_case(env, simflow_root, work, case, False)
        if rc == 0:
            raise SystemExit(f"{case} unexpectedly passed; see {console}")
        text = logs[node_log(logs, node)]
        if expected not in text:
            raise SystemExit(f"{case}: {node} log lacks '{expected}'; see {run_dir}")
        if expected == HS_TIMEOUT:
            advanced = re.search(r"local time advanced (\d+) ns", text)
            if advanced is None or int(advanced.group(1)) > HS_MAX_ADVANCE_NS:
                raise SystemExit(f"{case}: local time advanced too far while waiting "
                                 f"({advanced.group(1) if advanced else 'unknown'} ns > {HS_MAX_ADVANCE_NS}); see {run_dir}")
            expected = f"{expected} (local time advanced {advanced.group(1)} ns)"
        print(f"PASS {case}: SimFlow rc={rc}, {node} reported '{expected}' ({run_dir})")

    simv = work / "sim" / "default" / "exec" / "simv"
    config_dir = work / "config"
    config_dir.mkdir(exist_ok=True)
    for index, (args, expected) in enumerate(CONFIG_CASES):
        log = config_dir / f"config_{index}.log"
        subprocess.run([str(simv), "+UVM_TESTNAME=eth_seg_shm_test", *args, "-l", str(log)], cwd=config_dir, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=False, timeout=600)
        text = log.read_text(errors="replace") if log.is_file() else ""
        if not any(line.startswith("UVM_FATAL ") and expected in line for line in text.splitlines()):
            raise SystemExit(f"{' '.join(args)}: no UVM_FATAL '{expected}' in {log}")
        print(f"PASS config {' '.join(args)}: UVM_FATAL '{expected}' ({log})")
    print(f"ETH_SHM_COSIM_PASS green=2 red={len(RED_CASES)} config={len(CONFIG_CASES)}")


if __name__ == "__main__":
    main()
