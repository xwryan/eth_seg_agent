// eth_seg_agent 主 filelist：用大写 -F 引用（vcs -F <路径>/eth_seg_agent/eth_seg_agent.f），文件与 +incdir+ 都相对本文件目录，可在任意目录编译。
// 不拉入依赖：前置项目每个写一行 -F，依次为 aip_core/aip_core.f flow_control/flow_control.f net_packet/net_packet.f。
// 只编译根入口 eth_seg_agent_pkg.sv；在自己的 package/module 内 `include "eth_seg_agent_import.svh" 即可 import 本项目的 package。
// 含 net_packet 报文序列包 eth_net_packet_pkg 与线速序列包 eth_flow_pkg，因此需要 net_packet 与 flow_control；cfg 用 aip_core 宏读参，aip_core 要求 -timescale=1ns/1ps。
// bind wrapper 在 add-on eth_seg_agent_bind.f（bind 到已有 DUT 时才加，否则会成为多余顶层）。
+incdir+./
+incdir+./src
+incdir+./rtl
+incdir+./seq_lib
./eth_seg_agent_pkg.sv
