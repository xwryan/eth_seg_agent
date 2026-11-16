# 按 Ethernet 线速发送

`eth_flow_pkg::eth_flow_seq` 继承 `eth_base_seq`，在本项目 sequence 层复用
[`flow_control`](https://github.com/xwryan/flow_control) 的 `flow_control_pkg::rate_model`。
它按报文实际长度计算预算，写入已有事务字段 `gap_segments`；driver、agent、bind
和 net_packet 都不增加限速逻辑。默认按绑定端口的 100/200/400G 发送。

## 依赖与编译

需要包含 `src/flow_control_pkg.sv` 的 flow_control 版本；只有旧模型源码的版本不再满足
可选流控目标的依赖检查。流控类型统一属于 `flow_control_pkg`，本项目通过
`import flow_control_pkg::*;` 使用，不在 `eth_flow_pkg` 中重新 include 模型。

各仓库的 filelist 依赖在前、按以下顺序组合（`*_ROOT` 指向各自仓库根目录）：

```text
-f $AIP_CORE_ROOT/aip_core.f -f $NET_PACKET_ROOT/net_packet.f -f $FLOW_CONTROL_ROOT/flow_control.f
-f $ETH_SEG_AGENT_ROOT/eth_seg_agent.f -f $ETH_SEG_AGENT_ROOT/eth_seg_agent_net_packet.f
-f $ETH_SEG_AGENT_ROOT/eth_seg_agent_flow.f
```

`flow_control.f` 只编译一次 `flow_control_pkg.sv`，不要再混用组件的直接 include。
RM/SCB 等其它 package 如需流控模型，也直接 import `flow_control_pkg`，这样共享的是
同一套类/枚举类型。`eth_flow_pkg` 只提供 Ethernet 适配序列，不重新导出流控类型。

两个 package 均显式设置 `timeunit 1ns; timeprecision 1fs;`，模型返回值与调用者保持
同一时间单位，不依赖命令行默认 timescale。上游时间 API 的数值单位统一为 ns；其它
时间单位的调用作用域需先换算（时间参数除以本地 `1ns`，返回值用于延时则乘以本地
`1ns`）。基础 agent 与基础报文测试不需要此依赖。

## SV 使用

```systemverilog
import eth_flow_pkg::*;
// 在已启动的 UVM task 中，完成 agent connect、等待复位解除之后发送。
eth_flow_seq seq = eth_flow_seq::type_id::create("flow");
seq.pkt = prepared_packet; // 已构造的 net_packet_pkg::packet；不含前导和 Ethernet FCS。
seq.count = 1000;
seq.rate_gbps = 200.0;
seq.clk_freq_hz = 415039062.5;
seq.start(eth_seg_sequencer::get_sqr("eth0"));
// start 返回只表示入队完成；继续等待 monitor/scoreboard 和尾部 gap 排空。
```

要随机包长，派生业务类并覆写 `create_packet(index)`，每次完成随机化和 `do_pack()`。
公共 count 循环逐包调用该方法，实际 `raw_data.size()` 决定计费，不能用平均包长代替。
同一批次模型、计划时间和小数余量独立，发送期间锁定 sequencer，防止其它发送序列插包。

| 字段 | 默认值 | 含义 |
|---|---|---|
| `count` | 1 | 继承基础类的发包数，必须为正 |
| `rate_gbps` | 0 | SV 中 0 使用绑定端口速率；正值不能超过端口速率 |
| `clk_freq_hz` | 415039062.5 | 实际用户时钟频率，必须与环境一致 |
| `ifg_bytes` | 12 | 平均 IFG，允许 12～1000000 字节 |
| `random_rate` | 0 | 每包均匀选择目标速率，独立于随机包长 |
| `rate_min_gbps/rate_max_gbps` | 0/0 | 随机模式必须显式配置，满足 0 < min <= max <= rate |
| `wire_bytes_queued` | 0 | 本次批次已入队的线速计费字节数，不代表物理完成 |

格式和端口宽度直接从所绑定 `eth_seg_agent#(100/200/400)` 的 cfg 读取。
cfg 必须保持 `traffic_load_pct=100`、`random_load=0`；反压与 valid 模式可继续使用。
运行期间保持时钟频率和帧格式不变。时钟字段只是计算输入，不会自动生成、测量或跟踪时钟。
用手工单独创建的 sequencer、在 flow body 之外直接调用 `send_packet()` 会明确报错。
业务子类应复用 `body()`，只覆写 `create_packet()` 或 `packet_to_item()` 等扩展点。

## 计费与误差

正常无 FCS 输入帧在事务副本中补零到至少 60B，原始 packet 不变；codec 再按 cfg
处理前导/FCS。显式携带 FCS 的事务须至少 64B 且启用 include_fcs，不能对其隐式补齐并
重新计算 CRC。原样 runt、错误格式等负向测试继续使用 `eth_base_seq`。

令 L 为 DA 到 payload/padding 结束的字节数，不含前导和 FCS：

```text
wire_bytes = L + 4(FCS) + 8(preamble/SFD) + ifg_bytes
interval_ns = wire_bytes × 8 / selected_rate_gbps
total_slots = interval_ns × clk_freq_hz / 1e9 × (port_rate / 25)
gap_budget = total_slots - ceil(interface_bytes / 8)
```

前导/FCS 透传只改变接口传输长度，不改变线上开销。RoCEv2 ICRC 已属于 L，不能再当作
Ethernet FCS 扣除。400G 是 MAC 线速口径，不重复扣 PCS/FEC 编码开销。

`gap_budget` 按累计向上取整，余量带到下一包。在无额外间隔、连续供包和连续 valid/ready 下，固定
速率的任意批内 SOP 前缀与目标累计预算相差小于一个 segment，且不会提前于该预算。
不能要求每拍或每个极短观察窗口恰好等于目标值。每批重新初始化，批次边界最多增加一个
segment 的取整等待；最后一包也附带 gap，吞吐统计应明确观察窗口边界。

用户在转换子类中设置的 `item.gap_segments` 是额外最小间隔，取两者较大值。
ready/valid 气泡不消耗已有 gap；出现反压、供包不足、额外间隔时实际速率会降低，
不会用积累的额度在恢复后补发。此方案不提供基于真实墙钟的令牌桶补偿。

随机速率模式逐包调用同一上游模型，选择范围内的速率。混合报文的平均带宽为
`Σwire_bits / Σ(wire_bits / selected_rate)`，不是 min/max 的算术平均值，也不是随机包长。
本次未直接启用上游 token_bucket/random/step 模型，避免把其突发或计划时间语义误认为
严格接口限速；多业务队列仲裁也不属于本次适配。

## Tcl 每次调用传参

网络报文 AIP 示例现在继承 `eth_flow_seq`。`aip_cmd_seq` 处理 count/time；包装类从
本次命令解析其它字段，不引入持久 env 配置。参数单位为 Gbps、Hz、字节：

```tcl
eth0_net_send count=1000 rate_gbps=400 clk_freq_hz=415039062.5
eth1_net_send count=500 rate_gbps=100 ifg_bytes=12
eth2_net_send count=500 mode=random_rate rate_min_gbps=50 rate_max_gbps=200
```

命令名称必须指向实际具有相应速率的 agent，例如第一行要求 eth0 是 400G 端口。
省略 rate_gbps 使用端口速率；Tcl 中显式速率和频率必须是完整的正实数。
`mode` 支持 `fixed`（默认）和 `random_rate`。报文协议/长度字段仍使用原有 set_param。
time 模式到期只取消 sequence，已经被 driver 接收的包和间隔仍需环境等待完成或复位。

## 验证

在 10.11.10.53 载入 VCS/license 环境：

```bash
make flow-test NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control SEED=7
make flow-test NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control FLOW_CLOCK_HZ=402832031.25 SEED=7
make net-packet-aip-test NET_PACKET=/path/to/net_packet \
  FLOW_CONTROL=/path/to/flow_control AIP_CORE=/path/to/aip_core SEED=7
```

核心测试包含 12 条 link（100/200/400G × 四种前导/FCS 组合）、双向随机/边界包长、
满速/半速/随机速率/反压阶段；观察真实 SOP 槽位和采样时间，并逐字节核对 monitor 帧。
AIP 测试通过真实 Tcl 参数核对实际包间距。测试使用 VIP 与响应壳，不包含厂商 MAC RTL。
flow_control 自带 report 统计计划时间，不能替代这些物理带宽观察。

2026-11-03 已在 53 的 VCS W-2024.09-SP1 / UVM 1.2、seed=1 完成验证：

| 测试 | 结果 |
|---|---|
| 415.0390625MHz | 96 组物理速率检查，12288 帧，5 个精确负向检查通过 |
| 402.83203125MHz | 复用同一 binary，96 组物理速率检查、12288 帧通过 |
| AIP Tcl | 四个命名端口 3/3/1/4 帧通过，50G/额外 IFG/随机范围实际间隔通过 |

所有最终测试 UVM WARNING/ERROR/FATAL 为 0；预期负向的 5 个 fatal 由精确 ID catcher
捕获。两个频点满速场景的实测/目标比值范围分别为 0.99993813～0.999997885 和
0.999941215～0.999995145，差异来自有限窗口末端的小数 segment 取整。
本地完整日志保存在忽略目录 `results/flow_validation/final/`，不作为产品依赖提交。

同日切换为 `flow_control_pkg` 后，在相同主机、VCS/UVM 版本和 seed 下完成回归：
两个频点各 96 组检查和 5 个预期负向检查、AIP 四端口 3/3/1/4 帧均通过，最终 UVM
WARNING/ERROR/FATAL 为 0，flow/AIP 编译器 warning 为 0。上游新增 package 的
跨作用域类型/时间换算测试通过，原六组测试共 89 passed、0 failed；原用例仍输出
49 条未注册统计队列的运行期提示。此次日志位于 `results/flow_package_validation/`。
