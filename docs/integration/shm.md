# SHM 联仿：两个仿真背靠背

两个各带 DUT 的仿真经 SimFlow 的 SHM 联仿（`def_shm_cosim`）连在一起：A 的以太网 TX 进 B 的 RX，
B 的 TX 进 A 的 RX，例如在两个 DUT 之间验证有状态的 RDMA RC。MAC active agent 打开 `shm` 后，
TX monitor 在 EOP 发布的每帧编码进 SHM fabric，fabric 收到的帧经 agent 自身 sequencer/rx_driver
回灌 RX，与 [loopback](bind.md#5-loopback) 走同一条路径，只是对端换成另一个仿真进程。一个仿真里可以有
任意多个 `shm=1` 的 agent（例如 DUT 的 4 个 100G 口 eth0..eth3），两边同名的链路两两相连、同时收发（第 3 节）。

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
- AIP Tcl 需要 Tcl bridge 的读写/force 权限：本仓库测试用 `-debug_access+all`，rdma_work 的 DPU 示例用 `-debug_access+r+w+f`
  也可以；全局 `-timescale=1ns/1ps`。UVM 1.2（本仓库 `-ntb_opts uvm-1.2`）与 UVM 1.1d（DPU 集成的 `-ntb_opts uvm`）都已验证。

## 2. 打开方式与参数

`+<agent>.shm=1`（即 `cfg.shm`，构建期读一次）。只允许 role=ETH_SEG_MAC 且 UVM_ACTIVE；与 `loopback` 互斥，
同时打开时 validate 报 `loopback and shm are mutually exclusive`，运行中再用 `set_param` 打开 loopback 报
`ETH_SHM_LOOPBACK`。agent 构建时按名字创建 `<agent>.shm_link`（`eth_seg_shm_link_<RATE>`），test/env 不用改代码；
没编译 `eth_seg_shm_pkg` 却置 `shm=1` 时报 `ETH_AGENT_SHM`。一个仿真可以有任意多个 `shm=1` 的 agent，速率可以不同；
它们共用本进程唯一的 SHM 端口（第 3 节），binding 名固定为 `default`，SimFlow 节点不用写 `tx`/`rx`。

以下参数按 agent 路径经 aip 读取，例如 `+eth0.shm_queue_depth=512`。`shm_link` 只属于本链路；其余都是节点级参数，
同一仿真的各 `shm=1` agent 必须相同（不同即构建期 `ETH_SHM_CFG` fatal，指出哪两个 agent 的哪个参数不同），
用叶名形式 `+shm_idle_sleep_us=20` 可以一次给全部 agent：

| 参数 | 缺省 | 含义 |
|---|---:|---|
| `shm_link` | agent 叶名 | 链路名：与对端同名的链路相连；本仿真内唯一；1..64 个字母、数字或 `_ . -`（第 3 节） |
| `shm_queue_depth` | 256 | adapter/endpoint 各级队列、每条链路的解码队列与未取走控制信号的上限，满即 fatal；多条链路时不得小于链路数 |
| `shm_max_frame` | 2032 | 每帧 SHM 载荷上限 = 链路头（3 + 链路名长度）+ 以太网帧（含 FCS）；须不超过 fabric `slot_size - 16`，大帧（如 RDMA MTU 4096）两者一起调大 |
| `shm_tx_timeout_ms` | 1000 | fabric 满或对端暂停时，单帧发送重试的墙钟上限（每次重试睡 1ms），超时 fatal |
| `shm_idle_sleep_us` | 0 | 接收空闲时每次轮询（仿真时间 100ns）在宿主侧休眠的微秒数，见第 5 节 |
| `shm_wait_poll_ns` | 1 | 控制信号等待时每次轮询推进的仿真时间（ns），等待期间 endpoint 也按它轮询，见第 6 节 |
| `shm_wait_sleep_us` | 1000 | 控制信号等待时每次轮询在宿主侧休眠的微秒数（< 1000000） |
| `shm_wait_timeout_ms` | 600000 | `eth_shm_wait` 不给 `timeout_ms` 时的墙钟上限（ms） |
| `shm_link_check` | 0 | 1：就绪后与对端交换并核对链路名集合，不一致在开始时即 fail closed（第 3 节）；两端须同时打开 |

传输参数全部由 SimFlow 按拓扑生成，不手写：`+SHM_ENABLE=1 +SHM_KEY +SHM_PORT_ID +SHM_DIRECTION
+SHM_DST_PORT +SHM_EXPECT_PORT_MASK +SHM_READY_TIMEOUT_MS +SHM_TX_BINDINGS +SHM_RX_BINDING`。
`shm=1` 而没有 `+SHM_ENABLE=1` 时报 `ETH_SHM_CFG`。节点 Tcl 由 SimFlow 在用例脚本前插入
`shm_wait_ready timeout_ms=...`。

## 3. 多条链路

shm_work 每个进程只允许一个 endpoint、一个 switch 端口，只有一个 RX binding，帧里也没有链路号；SimFlow 节点只有一个
`port` 和一个 `to`。所以一个仿真的全部 `shm=1` agent 复用这一个端口：首个构建的 `shm=1` agent 在自己的 `shm_link` 下创建
`shm_hub`（`eth_seg_shm_hub`，不带速率参数）、`endpoint` 与 `adapter`，其余 agent 登记到同一个 hub。

- **链路名**：缺省取 agent 叶名（bind wrapper 的 `AGENT_NAME`，如 `eth0`），`+<agent>.shm_link=<名字>` 可改。数据帧带上
  链路名，接收端交给同名链路。两个节点的链路名须两两对应，agent 名与顺序可以不同（例如对端叫 `mac0` 的 agent 设
  `+mac0.shm_link=eth0`）。同一仿真里两个 agent 用了同一个链路名：构建期 `ETH_SHM_CFG` fatal；`shm_link` 要按 agent
  路径给，叶名形式 `+shm_link=x` 会让所有 agent 同名。只有一条链路时同样按名字匹配，所以两端 agent 叶名不同时要用
  `shm_link` 对齐。
- **对端没有的链路**：收到的数据帧带的链路名本端没有，立即 `ETH_SHM_LINK` fatal（fail closed，不丢弃、不交给别的链路），
  例如 `SHM frame from port 1 names link 'eth3', but this simulation has no shm=1 agent with that link name (local links:
  eth0,eth1,eth2,eth9)`。对端不是同一版本的 eth_seg_agent（帧头不对）报 `ETH_SHM_FORMAT` fatal。
- **开始时核对**（`shm_link_check=1`，两端都要打开）：就绪后（仿真时间 0）各自把链路名集合（按字典序、逗号连接）作为一个
  控制帧发给对端，排在任何数据帧之前；收到后比较，不一致即 `ETH_SHM_LINKS` fatal，例如 `SHM link set differs from the peer:
  local eth0,eth1,eth2,eth9, peer eth0,eth1,eth2,eth3 (only local: eth9; only peer: eth3)`（先收到对端集合的一端报告，SimFlow
  随即结束整组节点，另一端可能来不及报告），一致时打印 `SHM link set matches the peer (...)`。不等对端，不拖慢仿真；结束时仍
  没收到对端的集合报 `ETH_SHM_LINKS`（UVM_ERROR）。对端发来的集合无论本端是否打开都会核对。打开后两端的 endpoint 各多收发
  一帧（`shm_transport` 期望要加上），这一帧不计入 `ctrl_sent/ctrl_received`。
- **公共部分**：所有链路的帧（和控制帧）走同一条 TX 队列，保序；`shm_queue_depth` 同时限制共用队列与每条链路自己的解码队列，
  某条链路收得慢、积压超限即 fatal（诊断带链路名）。复位按链路：某条链路 TX 复位只从共用 TX 队列移除该链路的帧，RX 复位只清
  该链路的解码队列。控制通道属于节点（第 6 节），与链路数无关。
- **拓扑限制**：一个节点只有一个 `to`，它的全部链路连到同一个对端节点；不能让 eth0 连 B、eth1 连 C。

## 4. 帧、错误帧与复位

- **线上格式**：SHM 载荷由链路头加线上帧组成。链路头为 `'E'`、类型 `'D'`、链路名长度（1B）与链路名；线上帧为 DA..payload
  加 4 字节 FCS，不含前导（两端各自按 `preamble_passthrough` 去掉/补上）。TX 已带 FCS（skip_crc）时原样保留，否则补正确 CRC。
  接收端按本链路的 `include_fcs` 保留或剥离 FCS，`rx_fcs_error` 只反映载荷 FCS 是否正确；两端、各链路的 FCS 设置互不影响。
  链路头只在两个 eth_seg_agent 之间，DUT 看到的帧不变。以太网帧（含 FCS）最长 `shm_max_frame - 3 - 链路名长度`，例如缺省
  2032 与链路名 `eth0` 时为 2025B。
- **错误帧**：带 EOP error 的 TX 帧把 FCS 改成正确 CRC 取反后发出（像 MAC 发错误帧），对端 RX 必报
  `rx_fcs_error`；自带坏 FCS 的帧原样发出，对端同样报 FCS 错。两种帧都报一次 `ETH_SHM_TX_ERROR`（UVM_ERROR），
  正文含帧序号、长度、错误类型与去向，例如
  `eth0: TX frame #7 (289 bytes) has EOP error; sent to SHM with the FCS inverted`；故意注错的测试用
  report catcher 或 `+uvm_set_severity` 降级。与 loopback 不同，EOP error 不会作为好帧到达对端。
- **不发送的帧**：TX monitor 已报格式错误的帧（aborted）、去掉 FCS 后不足 9B 的帧（`ETH_SHM_LEN`）、
  本节点没有目的端口（RX_ONLY）时的帧（`ETH_SHM_NO_ROUTE`）都不发送并计入 dropped；连同链路头超过 `shm_max_frame`
  的帧直接 fatal。
- **RX 回灌**：常驻 owner sequence 在 agent 自身 sequencer 上逐帧取本链路的解码队列，交 rx_driver；与用户 RX
  sequence 按帧仲裁交错，RX monitor 对两类帧一视同仁。
- **复位**（shm_work 模板的做法，按方向拆开）：TX 复位断言从 adapter 的 TX 队列移除本链路的帧，endpoint 已收下的帧视为
  已上线路；RX 复位断言清本链路的解码队列并推进复位代次，owner 逐帧判旧，rx_driver 丢弃的在途帧计入 flushed。
  RX 复位期间 owner 等复位释放再驱动：两个进程没有时间同步，对端早到的帧不算复位期间的帧；复位持续而对端
  仍在发帧时帧在解码队列积压，超过 `shm_queue_depth` 即 fatal。仿真开始按复位处理，首个复位通知不算断言沿。
- **统计**：只有一条链路时 report_phase 打印 `ETH_SHM: eth0: sent=… received=… driven=… flushed=… dropped=… tx_errors=…
  pending=… ctrl_sent=… ctrl_received=… ctrl_dropped=… ctrl_unclaimed=…`（后四项是第 6 节的控制信号，`ctrl_unclaimed` 列出
  结束时仍未被 `eth_shm_wait` 取走的信号名，没有时为 `none`）。多条链路时每条链路一行 `ETH_SHM: <agent>: link=<名字> sent=…
  received=… driven=… flushed=… dropped=… tx_errors=… pending=…`，hub 另打印一行 `ETH_SHM: links=<链路名> ctrl_sent=…
  ctrl_received=… ctrl_dropped=… ctrl_unclaimed=…`。shm_work 另打印 `SHM_ENDPOINT_COUNTERS` 与 `SHM_ADAPTER_STATS`（全部
  链路之和），endpoint 与 adapter 的 TX 帧数含控制帧，字节数含链路头。

## 5. 就绪、超时与两个进程的时间

- **就绪**：hub 在仿真时间 0 等待 fabric 就绪（本端 endpoint 打开且所有端口上线），等的是墙钟，上限
  `+SHM_READY_TIMEOUT_MS`（SimFlow `fabric.ready_timeout`），失败 fatal。等待期间仿真时间不前进，DUT 的
  第一帧必在就绪之后；打开端口的重试也以同一超时为上限。之后 Tcl 里的 `shm_wait_ready` 立即返回。
- **fail closed**：任何队列满（如 `decoded source FIFO is full`）、switch 计数到丢包（`SHM_HEALTH_DROP`）、
  发送重试超过 `shm_tx_timeout_ms`、收到本端没有的链路名都会 fatal，SimFlow 随即结束整组节点。
- **常驻等待**：owner sequence 等下一帧、等 RX 复位释放时不提 objection，和 loopback 的常驻 sequence
  一样不阻止测试结束；测试的完成等待（end_test、scoreboard）须自带超时。
- **没有时间同步**：两个进程的仿真时间各走各的，只靠墙钟就绪屏障对齐起点。等待对端的一方空闲轮询很便宜，
  仿真时间会跑得很快，基于仿真时间的超时（AIP end_test、`::aip_ack_timeout_ns`、RDMA 重传定时器等）可能在
  对端还在工作时就到期；`shm_idle_sleep_us` 让空闲轮询在宿主侧睡一会儿，限制空闲方仿真时间的推进速度
  （例如 20us 对 100ns 轮询，空闲时每毫秒墙钟最多推进约 5us 仿真时间）。两边仿真速度差太多时接收积压会
  增长，超过 `shm_queue_depth` 即 fatal。
- **结束顺序**：先结束的节点会关掉自己的端口，之后再发给它的帧在 switch 计为丢包，发送方 fatal。
  每个节点应在确认对端不会再发帧后才结束（例如收齐对端每条链路的帧，协议上不再有重传）。最简单的做法是结束前互发一次
  控制信号（第 6 节）：各自 `eth_shm_signal name=<自己>_done`，再 `eth_shm_wait name=<对端>_done`，然后 `end_test`。

## 6. 带内控制信号（两个仿真之间的握手）

两个仿真之间没有别的通道。需要交换运行期才知道的内容（例如接收端建好 QP 后把 QPN、PSN、MAC/IP 告诉发送端），
或约定“我已就绪 / 我已结束”时，用 SHM 链路上的控制信号：

```tcl
eth_shm_signal name=rx_ready data={qpn=0x10 psn=0x000100 dmac=0x020000000002}   ;# 本端发
eth_shm_wait name=rx_ready timeout_ms=600000                                     ;# 对端等，结果 "OK: eth_shm_wait: <data>"
```

- **节点级**：控制信号属于两个仿真，不属于某条链路；有几条 `shm=1` 链路，命令与语义都一样。
- **命令**：`eth_shm_signal name=<名字> [data=<文本>]` 成功返回 `OK: eth_shm_signal: <名字>`；`eth_shm_wait name=<名字>
  [timeout_ms=<毫秒>]` 成功返回 `OK: eth_shm_wait: <数据>`（数据为空时冒号后为空），`timeout_ms` 缺省取
  `<agent>.shm_wait_timeout_ms`。失败都返回非零 status 与 `ERROR: <命令>: <原因>`，例如
  `ERROR: eth_shm_wait: no 'rx_ready' signal from the peer within 3000 ms (wall clock; local time advanced 2085 ns)`；
  未知键、重复键、非法名字或超时值在执行前拒绝。没有 `shm=1` 的链路时两条命令都返回 ERROR。
- **名字与数据**：名字 1..64 个字符，只含字母、数字与 `_ . : -`；数据至多 1000 个可打印 ASCII 字符（AIP 的命令
  与结果各限 1024 字节）。数据含空格、逗号或等号时用花括号包住（`data={a=1 b=2,3}`），最外一层花括号不属于数据，
  内部花括号须成对。
- **语义**：信号按名字排队缓存，先到的（对端早于本端 `eth_shm_wait` 发出）不丢；同名多个按到达顺序各取一个。
  `eth_shm_signal` 排在已交出的 DUT 帧之后（各链路共用一条 TX 队列，保序），等控制帧交到 switch 才返回。只收不发
  （RX_ONLY）的节点不能 signal，只发不收（TX_ONLY）的节点不能 wait。
- **时间**：`eth_shm_wait` 的上限是墙钟。等待期间每次轮询在宿主侧睡 `shm_wait_sleep_us`，仿真时间只推进
  `shm_wait_poll_ns`（endpoint 在等待期间也按它轮询），所以等对端初始化几分钟，本端仿真时间也只走几百微秒；
  轮询时报告 AIP 活动，命令看门狗不会把长等待当成死锁。超时、传输错误都返回 ERROR，不会挂起。
- **线上格式**：控制帧是普通以太网帧，DA 全 1、SA `02:00:00:00:00:00`、EtherType `0x88B5`（IEEE 本地实验类型），载荷
  依次为魔数 `ETHSHMC1`、名字长度（1B）、名字、数据长度（2B，大端）与数据，不足 60B 补零，带正确 FCS；SHM 头为 `'E'` 与
  类型 `'C'`（没有链路名）。对端 hub 在 endpoint 与 adapter 之间按类型截下，不交 rx_driver、不进 DUT、RX monitor 看不到；
  DUT 帧即使用了同样的 EtherType 与魔数也照常交给 DUT。EtherType、魔数、FCS 或长度错误的控制帧报 `ETH_SHM_CTRL`
  （UVM_ERROR）后丢弃；未取走的信号超过 `shm_queue_depth` 个即 fail closed。名字 `#links` 保留给链路名集合的核对。
- **计数**：控制帧计入 endpoint 的收发帧数（`SHM_ENDPOINT_COUNTERS`、shm_work 的 `shm_transport` 检查器的期望须加上），
  不计入各链路的 `sent/received/driven`；SV 中可读 `eth_seg_shm_hub::inst` 的 `ctrl_sent/ctrl_received/ctrl_dropped`
  （各链路的 `hub` 指向它）。

## 7. SimFlow 两节点示例

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

DUT 的 4 个 100G 口（`eth_seg_bind_wrapper #(.RATE(100), .AGENT_NAME("eth0"))` .. `"eth3"`）全部接到对端时，四个 agent
都置 `shm=1`，节点级参数用叶名一次给全部 agent；链路名取 agent 叶名，两端都是 eth0..eth3，eth0 对 eth0 ... eth3 对 eth3：

```yaml
def_tc:
  - name: dut_peer4
    test: my_rdma_test
    params:
      eth0.shm: 1
      eth1.shm: 1
      eth2.shm: 1
      eth3.shm: 1
      shm_idle_sleep_us: 20      # 叶名：四个 agent 相同（节点级参数必须相同）
    tcl: |
      run

def_shm_cosim:
  - name: dut_back_to_back_x4
    fabric: {key: auto, slots: 1024, slot_size: 2048, ready_timeout: 60s}
    params:
      shm_link_check: 1          # 可选：开始时核对两端链路名集合
    map:
      dut_a: {tc: dut_peer4, port: 0, to: dut_b}
      dut_b: {tc: dut_peer4, port: 1, to: dut_a}
```

`prun -y <spec> -tc dut_back_to_back -cmp`（或 `python3 -m simflow run --project <prj> --yaml <spec> --tc dut_back_to_back -cmp`）
先编译再启动 switch 与两个节点；两边可用不同 testcase 或节点级参数（如 `dut_b: {..., eth0.include_fcs: 1}`；节点 map 里的
参数名须带点号，叶名参数放在 testcase 或 cosim 的 `params`）。四条链路共用每个节点的一个 switch 端口，fabric 的 `slots` 按
最坏积压适当放大。帧长（含 FCS）超过 `shm_max_frame - 3 - 链路名长度`（缺省约 2025B）时把 `slot_size` 和 `shm_max_frame`
一起调大（`shm_max_frame <= slot_size - 16`）。完整可运行的工程见 `test/shm/base.prj.yaml` 与 `test/shm/eth_shm_cases.yaml`。

## 8. 验证

```bash
make shm-cosim-test AIP_CORE=/path/to/aip_core NET_PACKET=/path/to/net_packet FLOW_CONTROL=/path/to/flow_control \
  SHM_WORK=/path/to/shm_work SIMFLOW=/path/containing/simflow
```

`AIP_CORE` 需已 `make -C dist libs`，`SHM_WORK` 需已构建 `shm_switch`，`SIMFLOW` 是包含 simflow 包的目录。
脚本 `scripts/run_shm_cosim.py` 用 SimFlow 编译一次 `test/shm/tb_shm.sv`（单链路用 lb0，多链路用 100G 的 eth0..eth3 与
400G 的 eth4，没置 shm 的 link 保持复位、空闲），再跑十二个两节点用例（产物在 `build/shm_cosim/sim/cosim/<用例>/<run-id>/`）
与六个单进程配置检查，全部符合时打印 `ETH_SHM_COSIM_PASS green=4 red=8 config=6`：

- `eth_shm_pair`（须通过）：每个节点一条 100G link，CLIENT 代替 DUT 发 TX，MAC 置 `shm=1`。dut_a 发 120 帧
  （不带 FCS），dut_b 发 60 帧（带 FCS，第 3 帧坏 FCS、第 7 帧 EOP error），帧长与内容由共享 seed、流编号
  与帧号决定，两端各自生成；各自逐字节、按序核对对端帧（含 FCS 保留/剥离与 `rx_fcs_error`），并由 AIP
  `end_test strict=1` 等待 shm_work 的 `shm_transport` 检查器与本地比对检查器。两节点日志都须零 UVM_ERROR/FATAL。
- `eth_shm_pair_drop`、`eth_shm_pair_corrupt`（须失败）：dut_a 漏发第 5 帧、或把第 5 帧改一个字节，
  dut_b 在第 5 帧比对失败，SimFlow 判失败（先结束的 dut_b 关端口后 dut_a 的后续帧被丢，dut_a 也 fatal）。
- `eth_shm_pair_overflow`（须失败）：dut_b 的 RX 只有 1/16 拍有效、`shm_queue_depth=8`，积压超限 fail closed。
- `eth_shm_hs_pair`（须通过）：两节点各发 20 帧数据，同时节点 Tcl `test/shm/eth_shm_handshake.tcl` 经控制信号往返一次：
  dut_a 先核对本地拒绝（缺名字、非法名字、未知键与重复键、非法超时、200ms 等不到），再发 early、empty（空数据）与
  带数据的 hello；dut_b 等 hello、回 reply（回显数据），再取早已缓存的 early 与 empty；数据里的空格、逗号、等号与嵌套
  花括号须原样到达；最后交换 done_a/done_b 再 end_test。两节点都须打印 `ETH_SHM_HS_PASS`，控制帧计入 endpoint 期望。
- `eth_shm_hs_no_signal`（须失败）：dut_b 不发 hello，dut_a 的 `eth_shm_wait name=hello timeout_ms=3000` 在 3 秒墙钟后返回
  ERROR（Tcl 打印 `ETH_SHM_HS_FAIL`，SimFlow 判失败），之后两端仍交换 done_a/done_b 再结束（否则无事可做的 dut_b 先结束、
  关掉端口，dut_a 还在发的数据帧会被丢）；脚本另核对等待期间本端仿真时间推进不超过 100us（实测约 2us）。
- `eth_shm_mlink`（须通过）：每个节点四条 100G link（`eth_seg_shm_mlink_test`），链路名经 `shm_link` 设为 eth0..eth3，
  每条链路每个方向 40 帧同时收发；每条链路的流由发送节点与链路名决定，收端逐字节、按序核对对端同名链路的帧。dut_b 把
  eth0_mac/eth1_mac 的链路名对调（按名字分发，与 agent 顺序无关）；dut_a 的 eth2 发坏 FCS 与 EOP error 帧，dut_b 的 eth1_mac
  保留 FCS；两端 `shm_link_check=1`，dut_a 再经控制通道发一次 hello（节点 Tcl `test/shm/eth_shm_mlink.tcl`）。脚本核对每个节点
  四行 `ETH_SHM_MLINK_LINK`（收发 40/40、零比对错）、每条链路的 `ETH_SHM ... link=` 行、hub 的 `links=` 行与链路名集合一致。
- `eth_shm_mixed`（须通过）：每个节点一条 100G（eth0）与一条 400G（eth4）link 共用一个 SHM 端口，链路名取 agent 叶名。
- `eth_shm_mlink_unknown`（须失败）：dut_b 的第四条链路叫 eth9 且不发帧，dut_a 的 eth3 帧到达 dut_b 即 `ETH_SHM_LINK` fatal，
  诊断列出本端链路。
- `eth_shm_mlink_set_mismatch`（须失败）：同样的不一致，两端 `shm_link_check=1`，开始时（仿真时间 0）即 `ETH_SHM_LINKS` fatal，
  诊断列出两边独有的名字；先收到对端集合的一端报告，脚本要求至少一端报告且方向正确。
- `eth_shm_mlink_corrupt`、`eth_shm_mlink_drop`（须失败）：dut_a 只在一条链路上改第 5 帧一个字节（eth2）或漏发第 5 帧（eth1），
  dut_b 只有这条链路比对失败，脚本另核对其它链路没有比对错误。
- 配置检查（直接跑 simv，构建期 fatal）：`+lb0_mac.shm=1` 没有 `+SHM_ENABLE=1`；`shm` 与 `loopback` 同开；CLIENT 置 `shm`；
  两个 agent 用同一个链路名；两个 agent 的节点级参数不同（`shm_queue_depth`）；非法链路名。后三项另给一组 SHM 传输 plusarg
  （只在构建期解析，不连 switch）。
