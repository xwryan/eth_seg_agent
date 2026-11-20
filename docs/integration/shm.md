# SHM 联仿：两个仿真背靠背

两个各带 DUT 的仿真经 SimFlow 的 SHM 联仿（`def_shm_cosim`）连在一起：A 的以太网 TX 进 B 的 RX，
B 的 TX 进 A 的 RX，例如在两个 DUT 之间验证有状态的 RDMA RC。MAC active agent 打开 `shm` 后，
TX monitor 在 EOP 发布的每帧编码进 SHM fabric，fabric 收到的帧经 agent 自身 sequencer/rx_driver
回灌 RX，与 [loopback](bind.md#5-loopback) 走同一条路径，只是对端换成另一个仿真进程。

SHM 数据面、UVM 框架与 switch 来自 [shm_work](https://github.com/Beihang-yuting/shm_work)（按
`shm_switch/docs/adapter_template.md` 的模板接入，框架代码不改动）。本项目只增加可选的
`eth_seg_shm_pkg` 与 `eth_seg_agent_shm.f`；不编译它们时，`eth_seg_agent.f` 和全部原有行为不变。

## 1. 依赖与编译

| 依赖 | 版本 | 用途 |
|---|---|---|
| shm_work | `09f8e6d4a5800b9f6781ef16fb47927fd2332b74`（已验证） | `shm_base.f`（DPI 声明与 `shm_uvm_pkg`）、`aip/shm_aip_pkg.sv`、endpoint C 实现、`shm_switch` |
| aip_core | 本项目的常规依赖 | 读参宏；`shm_aip_pkg` 的 `shm_wait_ready` 命令与 end checker |
| SimFlow | 支持没有 TX_ONLY 节点的拓扑 | 启动 switch 与各节点、分配 SHM key、生成 `+SHM_*` |

先在 shm_work 里构建 switch：`make -C $SHM_WORK_ROOT/shm_switch shm_switch`，SimFlow 经 `SHM_SWITCH_BIN`
或 `PATH` 找到它。仿真按以下顺序编译（本项目与前置项目每个一行大写 `-F`，路径相对各 filelist；shm_work 的
`shm_base.f` 内部经 `$SHM_WORK_ROOT` 定位，按 shm_work 的用法用 `-f`）：

```text
-F <ws>/aip_core/aip_core.f
-F <ws>/flow_control/flow_control.f
-F <ws>/net_packet/net_packet.f
-F <ws>/eth_seg_agent/eth_seg_agent.f
-F <ws>/eth_seg_agent/eth_seg_agent_bind.f             # 用 bind wrapper 时
-f $SHM_WORK_ROOT/shm_switch/files/shm_base.f
$SHM_WORK_ROOT/shm_switch/aip/shm_aip_pkg.sv
-F <ws>/eth_seg_agent/eth_seg_agent_shm.f              # 可选 add-on：eth_seg_shm_pkg
-CFLAGS -DDPI_MODE $SHM_WORK_ROOT/shm_switch/shm_switch_core.c $SHM_WORK_ROOT/shm_switch/shm_switch_port.c
```

- 前四行（加可选的 bind add-on）是 eth_seg_agent 的常规编译顺序，见 README。
- 在自己的 package/module 内写一行 `` `include "eth_seg_agent_shm_import.svh" `` 即可 import `eth_seg_shm_pkg`
  （与 `eth_seg_agent_import.svh` 一样每个使用处 include 一次）；shm_work 的 `shm_uvm_pkg`、`shm_aip_pkg` 按需自己 import。
- 不要用 shm_work 的 `shm_aip.f`：它会再编译一次 `aip_core_pkg`。上面单列 `shm_aip_pkg.sv` 与之等价。
- VCS 的 `-F` 不改写 C 源文件路径，C 文件按绝对路径（`$SHM_WORK_ROOT`）给出。
- endpoint 的 C 实现静态链接进 simv；也可以按 shm_work 的 `docs/simflow_cosim.md` 用 UCLI `loaddl`
  加载 `libshm_switch_dpi.so`，两种方式只能选一种。
- AIP Tcl 需要 `-debug_access+all`（与本项目其它 AIP 测试相同），全局 `-timescale=1ns/1ps`。

## 2. 打开方式与参数

`+<agent>.shm=1`（即 `cfg.shm`，构建期读一次）。只允许 role=ETH_SEG_MAC 且 UVM_ACTIVE；与 `loopback` 互斥，
同时打开时 validate 报 `loopback and shm are mutually exclusive`，运行中再用 `set_param` 打开 loopback 报
`ETH_SHM_LOOPBACK`。agent 构建时按名字创建 `<agent>.shm_link`（`eth_seg_shm_link_<RATE>`），test/env 不用改代码；
没编译 `eth_seg_shm_pkg` 却置 `shm=1` 时报 `ETH_AGENT_SHM`。一个仿真只能有一个 `shm=1` 的 agent
（每个进程一个 endpoint，binding 名固定为 `default`，SimFlow 节点不用写 `tx`/`rx`）。

以下参数按 agent 路径经 aip 读取，例如 `+eth0.shm_queue_depth=512`：

| 参数 | 缺省 | 含义 |
|---|---:|---|
| `shm_queue_depth` | 256 | adapter/endpoint 各级队列与解码队列的深度，满即 fatal |
| `shm_max_frame` | 2032 | 含 FCS 的最大帧长；须不超过 fabric `slot_size - 16`，大帧（如 RDMA MTU 4096）两者一起调大 |
| `shm_tx_timeout_ms` | 1000 | fabric 满或对端暂停时，单帧发送重试的墙钟上限（每次重试睡 1ms），超时 fatal |
| `shm_idle_sleep_us` | 0 | 接收空闲时每次轮询（仿真时间 100ns）在宿主侧休眠的微秒数，见第 4 节 |

传输参数全部由 SimFlow 按拓扑生成，不手写：`+SHM_ENABLE=1 +SHM_KEY +SHM_PORT_ID +SHM_DIRECTION
+SHM_DST_PORT +SHM_EXPECT_PORT_MASK +SHM_READY_TIMEOUT_MS +SHM_TX_BINDINGS +SHM_RX_BINDING`。
`shm=1` 而没有 `+SHM_ENABLE=1` 时报 `ETH_SHM_CFG`。节点 Tcl 由 SimFlow 在用例脚本前插入
`shm_wait_ready timeout_ms=...`。

## 3. 帧、错误帧与复位

- **线上格式**：SHM 载荷是线上帧，即 DA..payload 加 4 字节 FCS，不含前导（两端各自按
  `preamble_passthrough` 去掉/补上）。TX 已带 FCS（skip_crc）时原样保留，否则补正确 CRC。接收端按自己的
  `include_fcs` 保留或剥离 FCS，`rx_fcs_error` 只反映载荷 FCS 是否正确；两端的 FCS 设置互不影响。
- **错误帧**：带 EOP error 的 TX 帧把 FCS 改成正确 CRC 取反后发出（像 MAC 发错误帧），对端 RX 必报
  `rx_fcs_error`；自带坏 FCS 的帧原样发出，对端同样报 FCS 错。两种帧都报一次 `ETH_SHM_TX_ERROR`（UVM_ERROR），
  正文含帧序号、长度、错误类型与去向，例如
  `eth0: TX frame #7 (289 bytes) has EOP error; sent to SHM with the FCS inverted`；故意注错的测试用
  report catcher 或 `+uvm_set_severity` 降级。与 loopback 不同，EOP error 不会作为好帧到达对端。
- **不发送的帧**：TX monitor 已报格式错误的帧（aborted）、去掉 FCS 后不足 9B 的帧（`ETH_SHM_LEN`）、
  本节点没有目的端口（RX_ONLY）时的帧（`ETH_SHM_NO_ROUTE`）都不发送并计入 dropped；超过 `shm_max_frame`
  的帧直接 fatal。
- **RX 回灌**：常驻 owner sequence 在 agent 自身 sequencer 上逐帧取解码队列，交 rx_driver；与用户 RX
  sequence 按帧仲裁交错，RX monitor 对两类帧一视同仁。
- **复位**（shm_work 模板的做法，按方向拆开）：TX 复位断言清 adapter 的 TX 队列，endpoint 已收下的帧视为
  已上线路；RX 复位断言清解码队列并推进复位代次，owner 逐帧判旧，rx_driver 丢弃的在途帧计入 flushed。
  RX 复位期间 owner 等复位释放再驱动：两个进程没有时间同步，对端早到的帧不算复位期间的帧；复位持续而对端
  仍在发帧时帧在解码队列积压，超过 `shm_queue_depth` 即 fatal。仿真开始按复位处理，首个复位通知不算断言沿。
- **统计**：report_phase 打印 `ETH_SHM: eth0: sent=… received=… driven=… flushed=… dropped=… tx_errors=… pending=…`；
  shm_work 另打印 `SHM_ENDPOINT_COUNTERS` 与 `SHM_ADAPTER_STATS`。

## 4. 就绪、超时与两个进程的时间

- **就绪**：链路在仿真时间 0 等待 fabric 就绪（本端 endpoint 打开且所有端口上线），等的是墙钟，上限
  `+SHM_READY_TIMEOUT_MS`（SimFlow `fabric.ready_timeout`），失败 fatal。等待期间仿真时间不前进，DUT 的
  第一帧必在就绪之后；打开端口的重试也以同一超时为上限。之后 Tcl 里的 `shm_wait_ready` 立即返回。
- **fail closed**：任何队列满（如 `decoded source FIFO is full`）、switch 计数到丢包（`SHM_HEALTH_DROP`）、
  发送重试超过 `shm_tx_timeout_ms` 都会 fatal，SimFlow 随即结束整组节点。
- **常驻等待**：owner sequence 等下一帧、等 RX 复位释放时不提 objection，和 loopback 的常驻 sequence
  一样不阻止测试结束；测试的完成等待（end_test、scoreboard）须自带超时。
- **没有时间同步**：两个进程的仿真时间各走各的，只靠墙钟就绪屏障对齐起点。等待对端的一方空闲轮询很便宜，
  仿真时间会跑得很快，基于仿真时间的超时（AIP end_test、`::aip_ack_timeout_ns`、RDMA 重传定时器等）可能在
  对端还在工作时就到期；`shm_idle_sleep_us` 让空闲轮询在宿主侧睡一会儿，限制空闲方仿真时间的推进速度
  （例如 20us 对 100ns 轮询，空闲时每毫秒墙钟最多推进约 5us 仿真时间）。两边仿真速度差太多时接收积压会
  增长，超过 `shm_queue_depth` 即 fatal。
- **结束顺序**：先结束的节点会关掉自己的端口，之后再发给它的帧在 switch 计为丢包，发送方 fatal。
  每个节点应在确认对端不会再发帧后才结束（例如收齐对端的帧，协议上不再有重传）。

## 5. SimFlow 两节点示例

两个节点互为 `to`，SimFlow 解析为两个 BIDIR 节点；节点 params 以 plusarg 传给各自仿真：

```yaml
def_tc:
  - name: dut_peer
    test: my_rdma_test
    params:
      eth0.shm: 1
      eth0.shm_idle_sleep_us: 20
    tcl: |
      # 用例脚本：配置、发起业务、end_test ... run
      run

def_shm_cosim:
  - name: dut_back_to_back
    fabric: {key: auto, slots: 256, slot_size: 2048, ready_timeout: 60s}
    map:
      dut_a: {tc: dut_peer, port: 0, to: dut_b}
      dut_b: {tc: dut_peer, port: 1, to: dut_a}
```

`prun -y <spec> -tc dut_back_to_back -cmp`（或 `python3 -m simflow run --project <prj> --yaml <spec> --tc dut_back_to_back -cmp`）
先编译再启动 switch 与两个节点；两边可用不同 testcase 或节点级参数（如 `dut_b: {..., eth0.include_fcs: 1}`）。
帧长超过 2028B 时把 `slot_size` 和 `eth0.shm_max_frame` 一起调大（`shm_max_frame <= slot_size - 16`）。
完整可运行的工程见 `test/shm/base.prj.yaml` 与 `test/shm/eth_shm_cases.yaml`。

## 6. 验证

```bash
make shm-cosim-test AIP_CORE=/path/to/aip_core NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control \
  SHM_WORK=/path/to/shm_work SIMFLOW=/path/containing/simflow
```

`AIP_CORE` 需已 `make -C dist libs`，`SHM_WORK` 需已构建 `shm_switch`，`SIMFLOW` 是包含 simflow 包的目录。
脚本 `scripts/run_shm_cosim.py` 用 SimFlow 编译一次 `test/shm/tb_shm.sv`，再跑四个两节点用例（产物在
`build/shm_cosim/sim/cosim/<用例>/<run-id>/`）：

- `eth_shm_pair`（须通过）：每个节点一条 100G link，CLIENT 代替 DUT 发 TX，MAC 置 `shm=1`。dut_a 发 120 帧
  （不带 FCS），dut_b 发 60 帧（带 FCS，第 3 帧坏 FCS、第 7 帧 EOP error），帧长与内容由共享 seed、流编号
  与帧号决定，两端各自生成；各自逐字节、按序核对对端帧（含 FCS 保留/剥离与 `rx_fcs_error`），并由 AIP
  `end_test strict=1` 等待 shm_work 的 `shm_transport` 检查器与本地比对检查器。两节点日志都须零 UVM_ERROR/FATAL。
- `eth_shm_pair_drop`、`eth_shm_pair_corrupt`（须失败）：dut_a 漏发第 5 帧、或把第 5 帧改一个字节，
  dut_b 在第 5 帧比对失败，SimFlow 判失败（先结束的 dut_b 关端口后 dut_a 的后续帧被丢，dut_a 也 fatal）。
- `eth_shm_pair_overflow`（须失败）：dut_b 的 RX 只有 1/16 拍有效、`shm_queue_depth=8`，积压超限 fail closed。
