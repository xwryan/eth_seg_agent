// eth_seg_agent 可选 add-on：SHM 联仿绑定 eth_seg_shm_pkg（MAC active agent 置 shm=1 时经 SimFlow SHM fabric 接到另一个仿真）。
// 只在 SHM 联仿时加入；不加时 eth_seg_agent.f 的内容与行为不变。
// 用大写 -F 引用（vcs -F <路径>/eth_seg_agent/eth_seg_agent_shm.f），路径相对本文件目录；不拉入依赖，前置每个写一行 -F，依次为
// aip_core/aip_core.f flow_control/flow_control.f net_packet/net_packet.f eth_seg_agent/eth_seg_agent.f，再加 shm_work（另一个仓库，
// 需设 SHM_WORK_ROOT）的 -f $SHM_WORK_ROOT/shm_switch/files/shm_base.f 与 $SHM_WORK_ROOT/shm_switch/aip/shm_aip_pkg.sv（不要用 shm_aip.f，
// 它会再编一次 aip_core_pkg）。endpoint 的 C 实现由工程编译流程链接（-CFLAGS -DDPI_MODE），见 docs/integration/shm.md。
// 在自己的 package/module 内 `include "eth_seg_agent_shm_import.svh" 即可 import 本 add-on 的 package。
./src/eth_seg_shm_pkg.sv
