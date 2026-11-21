#!/usr/bin/env python3
"""SHM 联仿回归：用 SimFlow 跑两个 eth_seg_agent 节点的背靠背 BIDIR cosim。

先编译并跑通过用例：单链路 eth_shm_pair（两节点日志都须零 UVM_ERROR/FATAL 且有完成标记）、带内握手 eth_shm_hs_pair
（另须打印 ETH_SHM_HS_PASS）、多链路 eth_shm_mlink（每节点四条 100G link 同时双向收发，逐链路核对，另核对链路名集合与
hello）与混合速率 eth_shm_mixed（100G + 400G）；再复用同一 simv 跑预期失败的用例（故障注入、握手超时、链路名不一致、
单条链路改帧/丢帧），要求 SimFlow 判失败且对应节点日志出现诊断（单条链路故障时其它链路不得报比对错），握手超时期间
本端仿真时间只推进很少；最后不经 SimFlow 直接跑 simv，确认错误配置在构建期即 fail closed。
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
LINK_MARKER = "ETH_SHM_MLINK_LINK"
HS_TIMEOUT = "ERROR: eth_shm_wait: no 'hello' signal from the peer within 3000 ms"
# 握手超时期间本端仿真时间推进的上限（ns）：每次轮询只推进 shm_wait_poll_ns（缺省 1ns）。
HS_MAX_ADVANCE_NS = 100000
# 须通过的用例：handshake 表示两节点须打印 ETH_SHM_HS_PASS；links 为多链路用例每个节点的链路名（逗号连接，按字典序）、
# 每条链路的帧数与是否核对链路名集合。
GREEN_CASES = (
    {"case": "eth_shm_pair"},
    {"case": "eth_shm_hs_pair", "handshake": True},
    {"case": "eth_shm_mlink", "handshake": True, "links": "eth0,eth1,eth2,eth3", "frames": 40, "link_check": True},
    {"case": "eth_shm_mixed", "links": "eth0_mac,eth4_mac", "frames": 30},
)
# 预期失败的用例：(节点, 该节点日志中必须出现的诊断) 列表——all 要求每一项都出现，any 只要求至少一项（两端都可能先发现，
# 先失败的一端结束后 SimFlow 停掉整组，另一端可能来不及报告）——以及（单条链路故障时）该节点日志里不得出现的其它链路比对错误。
RED_CASES = (
    ("eth_shm_pair_drop", "all", (("dut_b", "peer frame #5"),), None),
    ("eth_shm_pair_corrupt", "all", (("dut_b", "peer frame #5: byte 20"),), None),
    ("eth_shm_pair_overflow", "all", (("dut_b", "decoded source FIFO is full"),), None),
    ("eth_shm_hs_no_signal", "all", (("dut_a", HS_TIMEOUT),), None),
    ("eth_shm_mlink_unknown", "all",
     (("dut_b", "names link 'eth3', but this simulation has no shm=1 agent with that link name "
                "(local links: eth0,eth1,eth2,eth9)"),), None),
    ("eth_shm_mlink_set_mismatch", "any",
     (("dut_a", "SHM link set differs from the peer: local eth0,eth1,eth2,eth3, peer eth0,eth1,eth2,eth9 "
                "(only local: eth3; only peer: eth9)"),
      ("dut_b", "SHM link set differs from the peer: local eth0,eth1,eth2,eth9, peer eth0,eth1,eth2,eth3 "
                "(only local: eth9; only peer: eth3)")), None),
    ("eth_shm_mlink_corrupt", "all", (("dut_b", "eth2_mac: peer frame #5: byte 20"),),
     r"\b(eth0_mac|eth1_mac|eth3_mac): peer frame #"),
    ("eth_shm_mlink_drop", "all", (("dut_b", "eth1_mac: peer frame #5"),),
     r"\b(eth0_mac|eth2_mac|eth3_mac): peer frame #"),
)
# 单进程错误配置：不启动 switch，agent/链路构建期即 fatal。需要两条链路走到 hub 的用例另给一组 SHM 传输 plusarg
# （只在 build 解析，不连 switch）。
SHM_ARGS = ("+SHM_ENABLE=1", "+SHM_KEY=0x5e5e0001", "+SHM_PORT_ID=0", "+SHM_DIRECTION=BIDIR",
            "+SHM_EXPECT_PORT_MASK=3", "+SHM_READY_TIMEOUT_MS=1000", "+SHM_DST_PORT=1",
            "+SHM_TX_BINDINGS=default", "+SHM_RX_BINDING=default")
CONFIG_CASES = (
    ("+lb0_mac.shm=1", ("+lb0_mac.shm=1",), "lb0_mac.shm=1 requires +SHM_ENABLE=1"),
    ("+lb0_mac.shm=1 +lb0_mac.loopback=1", ("+lb0_mac.shm=1", "+lb0_mac.loopback=1"),
     "loopback and shm are mutually exclusive"),
    ("+lb0_client.shm=1", ("+lb0_client.shm=1",), "shm requires role ETH_SEG_MAC and is_active UVM_ACTIVE"),
    ("duplicate link name", ("+eth0_mac.shm=1", "+eth1_mac.shm=1", "+eth1_mac.shm_link=eth0_mac", *SHM_ARGS),
     "eth1_mac: SHM link name 'eth0_mac' is already used by eth0_mac"),
    ("node parameters differ", ("+eth0_mac.shm=1", "+eth1_mac.shm=1", "+eth1_mac.shm_queue_depth=64", *SHM_ARGS),
     "eth1_mac.shm_queue_depth=64 differs from eth0_mac.shm_queue_depth=256"),
    ("invalid link name", ("+eth0_mac.shm=1", "+eth0_mac.shm_link=bad/name"),
     "eth0_mac: SHM link name 'bad/name' needs 1..64 letters, digits or _ . -"),
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


def check_links(case, node, log, text, spec):
    # 多链路：每条链路一行 ETH_SHM_MLINK_LINK（收发帧数齐、零比对错），hub 打印控制通道一行 links=<链路名>，
    # 每条链路各一行 ETH_SHM link=<名字>；打开 shm_link_check 时两端都须报告链路名集合一致。
    names = spec["links"].split(",")
    frames = spec["frames"]
    rows = re.findall(rf"\[{LINK_MARKER}\] link=(\S+) port=\S+ agent=\S+ sent=(\d+) received=(\d+) mismatches=(\d+)", text)
    seen = sorted(row[0] for row in rows)
    if seen != sorted(names):
        raise SystemExit(f"{case}: {node} reported links {seen}, expected {sorted(names)}; see {log}")
    for link, sent, received, mismatches in rows:
        if int(received) != frames or int(mismatches) != 0 or int(sent) != frames:
            raise SystemExit(f"{case}: {node} link {link} sent={sent} received={received} mismatches={mismatches}, "
                             f"expected {frames}/{frames}/0; see {log}")
    if f"[ETH_SHM] links={spec['links']} " not in text:
        raise SystemExit(f"{case}: {node} lacks the hub line 'links={spec['links']}'; see {log}")
    for link in names:
        if not re.search(rf"\[ETH_SHM\] \S+: link={re.escape(link)} sent=", text):
            raise SystemExit(f"{case}: {node} lacks the ETH_SHM line of link {link}; see {log}")
    if spec.get("link_check") and f"SHM link set matches the peer ({spec['links']})" not in text:
        raise SystemExit(f"{case}: {node} did not confirm the peer link set; see {log}")


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

    for index, spec in enumerate(GREEN_CASES):
        case = spec["case"]
        rc, run_dir, logs, console = run_case(env, simflow_root, work, case, index == 0)
        if rc != 0:
            raise SystemExit(f"{case} failed (rc={rc}); see {console} and {run_dir}")
        for node in ("dut_a", "dut_b"):
            log = node_log(logs, node)
            text = logs[log]
            subprocess.run([sys.executable, str(CHECK_LOG), str(log), "run", MARKER], check=True)
            if spec.get("handshake") and not any(line.startswith(HS_MARKER + " ") for line in text.splitlines()):
                raise SystemExit(f"{case}: {node} log lacks {HS_MARKER}; see {log}")
            if "links" in spec:
                check_links(case, node, log, text, spec)
            summary = [line for line in text.splitlines() if f"[{MARKER}]" in line]
            print(f"{node}: {summary[0].split(f'[{MARKER}] ', 1)[1]}")
        print(f"PASS {case}: {run_dir}")

    for case, mode, expected, forbidden in RED_CASES:
        rc, run_dir, logs, console = run_case(env, simflow_root, work, case, False)
        if rc == 0:
            raise SystemExit(f"{case} unexpectedly passed; see {console}")
        found = [(node, item) for node, item in expected if item in logs[node_log(logs, node)]]
        missing = [f"{node}: '{item}'" for node, item in expected if (node, item) not in found]
        if not found or (mode == "all" and missing):
            raise SystemExit(f"{case}: missing {'; '.join(missing)}; see {run_dir}")
        node, report = found[0]
        text = logs[node_log(logs, node)]
        if forbidden is not None:
            other = re.search(forbidden, text)
            if other is not None:
                raise SystemExit(f"{case}: {node} also reported '{other.group(0)}' on another link; see {run_dir}")
        if report == HS_TIMEOUT:
            advanced = re.search(r"local time advanced (\d+) ns", text)
            if advanced is None or int(advanced.group(1)) > HS_MAX_ADVANCE_NS:
                raise SystemExit(f"{case}: local time advanced too far while waiting "
                                 f"({advanced.group(1) if advanced else 'unknown'} ns > {HS_MAX_ADVANCE_NS}); see {run_dir}")
            report = f"{report} (local time advanced {advanced.group(1)} ns)"
        if forbidden is not None:
            report = f"{report}; no other link reported a mismatch"
        nodes = " and ".join(sorted({n for n, _ in found}))
        print(f"PASS {case}: SimFlow rc={rc}, {nodes} reported '{report}' ({run_dir})")

    simv = work / "sim" / "default" / "exec" / "simv"
    config_dir = work / "config"
    config_dir.mkdir(exist_ok=True)
    for index, (label, args, expected) in enumerate(CONFIG_CASES):
        log = config_dir / f"config_{index}.log"
        subprocess.run([str(simv), "+UVM_TESTNAME=eth_seg_shm_test", *args, "-l", str(log)], cwd=config_dir, env=env,
                       stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT, check=False, timeout=600)
        text = log.read_text(errors="replace") if log.is_file() else ""
        if not any(line.startswith("UVM_FATAL ") and expected in line for line in text.splitlines()):
            raise SystemExit(f"{label}: no UVM_FATAL '{expected}' in {log}")
        print(f"PASS config {label}: UVM_FATAL '{expected}' ({log})")
    print(f"ETH_SHM_COSIM_PASS green={len(GREEN_CASES)} red={len(RED_CASES)} config={len(CONFIG_CASES)}")


if __name__ == "__main__":
    main()
