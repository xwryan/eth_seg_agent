# Ethernet segmented UVM VIP

`eth_seg_pkg` 将事务、配置、驱动、监视器、agent 和 environment 统一打包。接口参数
`ETH_RATE_G` 仅支持 100、200、400；一个 `tb_top` 同时实例化三种宽度，测试通过类型化
`uvm_config_db` 传递独立 virtual interface。CLIENT active agent 驱动 TX，MAC active agent
驱动 RX 与 ready；两端可分别改为 passive 连接真实 DUT。

默认事务从目的 MAC 字节开始，不含前导和 FCS。配置 `preamble_passthrough` 或 `include_fcs`
后，codec/monitor 会处理 7×55、D5 前导及低字节优先 CRC32。`fcs_present` 明确表示事务已经
携带 FCS，`inject_fcs_error` 只在 FCS 开启时翻转 CRC；驱动 `item_done` 仅表示已复制入队，
物理完成须核对 `sent_ap`/monitor 的预期数量及 scoreboard 排空，不能仅凭 `is_idle()` 判定。

载入 VCS（UVM 1.2）与 license 环境后运行（全部目标都需 aip_core、net_packet、flow_control，`AIP_CORE`/`NET_PACKET`/`FLOW_CONTROL`
缺省取对应的 `*_ROOT`）：

```text
make compile RATE=100
make run RATE=200 TEST=eth_seg_smoke_test SEED=7
make regress
make bind-test SEED=7
make timing-test SEED=7
make timing-checker-test
make loopback-test SEED=7
make loopback-aip-test NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control SEED=7
```

日志位于 `build/<RATE>/logs/`，`scripts/check_log.py` 检查 UVM summary 和非零错误计数。
原 smoke testbench 是双 active VIP 自检；新增时序测试使用独立 HDL ready 源，均不包含厂商 F-Tile 加密 RTL 模型。

工程集成每个项目一行大写 `-F`（filelist 内路径相对它自己的目录，不需要 `*_ROOT`，可在任意目录编译；filelist 不拉入依赖），
按依赖顺序：

```text
-F <ws>/aip_core/aip_core.f            // cfg 用 aip_core 宏读参，需 -timescale=1ns/1ps
-F <ws>/flow_control/flow_control.f
-F <ws>/net_packet/net_packet.f
-F <ws>/eth_seg_agent/eth_seg_agent.f  // interface、types、package、checker、eth_net_packet_pkg、eth_flow_pkg
-F <ws>/eth_seg_agent/eth_seg_agent_bind.f   // 可选 add-on：bind wrapper，bind 到已有 DUT 时才加
```

`eth_seg_agent.f` 只编译根入口 `eth_seg_agent_pkg.sv`（按原顺序 include 上述源码）；在自己的 package/module 内写一行
`` `include "eth_seg_agent_import.svh" `` 即可 import `eth_seg_types_pkg`、`eth_seg_pkg`、`eth_net_packet_pkg`、`eth_flow_pkg`。
原可选 filelist `eth_seg_agent_net_packet.f`、`eth_seg_agent_flow.f` 已并入 `eth_seg_agent.f` 并删除，因此 net_packet、flow_control
成为所有目标的前置。Makefile 的 `AIP_CORE`/`NET_PACKET`/`FLOW_CONTROL` 缺省取对应的 `*_ROOT`。
aip_core 自带的 `aip_clk.sv` 声明 `timescale 1ns/1fs`，全局精度因此为 1fs。

agent build 开头按登记名（bind 时即 `AGENT_NAME`）用 aip_core 宏读取 cfg 全部字段，未给出的保持现值，
例如 `+eth0.include_fcs=1 +eth0.role=ETH_SEG_MAC +eth0.max_pending=8`（Tcl bridge 在 run 阶段才工作，build 读参用 plusarg）。
role/is_active/eth_rate_g 决定组件构建，只在 build 读取一次；aip 的叶名回退会让 `+include_fcs=1` 作用于所有 agent。

`gap_segments` / sequence 的 `inter_frame_gap` 以有效 idle segment 计数，TX/RX 均执行。
固定/随机负载按每帧占用的 segment 数换算间隔，外部 ready/valid 气泡不消费该计数。
真实 DUT 正沿更新 ready、包内停顿、复位恢复及 checker 字段有效范围见
[时序审查与定向回归](docs/development/timing-audit.md)。

接入真实 DUT 时，agent 只从 `cfg.vif` 取接口：父组件可直接写 `agent.cfg`，否则 agent 在 build 时按键 `"cfg"`
读取 `uvm_config_db#(eth_seg_config#(RATE))`（monitor/coverage 单独使用时同样回退到该键；`eth_seg_env` 两种都做）。
VIP 不读取名为 `"vif"` 的 config_db 项；testbench 可自行用类型化句柄把接口交给 test，例如 smoke 的
`uvm_config_db#(virtual eth_seg_if#(200))::set(null, "uvm_test_top", "vif200", eth_if200)`，再写入 `cfg.vif`。
cfg 与 vif 的 RATE 必须一致，`eth_seg_config#(200).eth_rate_g` 也必须保持 200，否则 agent build 会立即报告错误。
bind wrapper 直接设置 `cfg.vif`，另发布 `<AGENT_NAME>_agent`/`_cfg`/`_vif` 三个键供 test 取用。

如需把 interface 和 root agent 封装在一个 module 里，再用 `bind` 挂到已有 DUT 的 MAC 接口 net 上，
使用 [eth_seg_bind_wrapper](bind/eth_seg_bind_wrapper.sv)，只需要 `AGENT_NAME` 和 `RATE`。
cfg 保持默认值，顶层 `#0; run_test();` 启动；agent 自动发布静态
`eth_seg_sequencer::sqr[agent_name]`，env 无需创建 agent 或转接 sequencer。
完整接线、配置与时序约定见 [bind 集成说明](docs/integration/bind.md)。

MAC active agent 支持 loopback：TX monitor 采到的每帧经有界队列（`max_pending`）和自身 sequencer
原样交给 rx_driver 回灌 RX，可用于 VTX → DUT → ETH TX → ETH RX → DUT → VRX 端到端测试。开关 `cfg.loopback`
按帧经 aip 重读，`+eth0.loopback=1` 或运行中 `set_param path=eth0.loopback value=0/1` 即可。开启期间带 EOP error
或坏 FCS 的 TX 帧照样原样回环，同时报 `ETH_LOOPBACK_TX_ERROR`（UVM_ERROR）；故意注错的测试用
`'+uvm_set_severity=*,ETH_LOOPBACK_TX_ERROR,UVM_ERROR,UVM_WARNING'` 或 report catcher 降级。
FCS 处理、复位与溢出语义见 [bind 集成说明](docs/integration/bind.md#5-loopback)。

[AIP Tcl 示例](examples/aip/eth_seg_aip_pkg.sv) 使用 aip_core 的 `aip_cmd_seq`
启动命名 sequencer，通过 `aip_int` 读取发包长度。
验证入口为 `make aip-test AIP_CORE=/path/to/aip_core`，包含四个 IP 的真实 Tcl 发包测试。

网络报文使用可选的 `eth_net_packet_pkg::eth_base_seq`：把
`net_packet_pkg::packet.raw_data` 转成独立字节事务，保留协议头、payload 和 RoCEv2 ICRC，
前导/Ethernet FCS 仍由 agent cfg 控制。支持直接设置 `seq.pkt` 后 `start(sqr)`，
支持 `count` 批量重放，或覆写 `create_packet()` 逐包生成；也可在业务 body 中调用 `send_packet(pkt)`。完整编译顺序、接口和网络报文 Tcl 示例见
[net_packet 集成说明](docs/integration/net_packet.md)。验证入口：

```bash
make net-packet-test NET_PACKET=/path/to/net_packet SEED=7
make net-packet-aip-test NET_PACKET=/path/to/net_packet AIP_CORE=/path/to/aip_core FLOW_CONTROL=/path/to/flow_control SEED=7
```

按 Ethernet 线速限流使用可选 `eth_flow_pkg::eth_flow_seq`，继承 `eth_base_seq`，
通过 import 复用外部 `flow_control_pkg::rate_model`（需先编译上游
`src/flow_control_pkg.sv`）。随机包长逐包计费，包含前导、FCS、padding 和
IFG，累计余量转成现有 gap_segments；agent/driver 无需增加限速逻辑。
网络报文 AIP 示例已接入该类，支持每次命令传 rate_gbps/clk_freq_hz，RoCEv2 另可传 psn_step/va_step 逐包递增。
使用方式、误差与反压边界见 [线速发送集成](docs/integration/flow.md)。

```bash
make flow-test NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control SEED=7
```

`eth_base_seq` 还提供 subscribe/mon_xaction/unsubscribe，一次取得 Monitor 已组好的
完整 Ethernet 帧。RM/SCB 使用 set_sequencer 关联长期对象；SCB 支持直接
write_before/write_after，passive agent 同样可取包。用法、复位协调与完整示例见
[整包采样及 RM/SCB 集成](docs/integration/sampling.md)。

```bash
make hub-test SEED=7
make sampling-test NET_PACKET=/path/to/net_packet SEED=7
```
