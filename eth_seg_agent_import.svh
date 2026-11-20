// eth_seg_agent 的 package import：在使用本项目的 package 或 module 内部写一行 `include "eth_seg_agent_import.svh"（eth_seg_agent.f 的 +incdir+./ 提供路径）。
// 只列本项目 eth_seg_agent.f 编译的 package；依赖项目的 import 由它们各自的 *_import.svh 提供。
// 故意不加 include guard：每个需要的 package/module 各 include 一次。
import eth_seg_types_pkg::*;
import eth_seg_pkg::*;
import eth_net_packet_pkg::*;
import eth_flow_pkg::*;
