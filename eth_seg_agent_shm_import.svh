// eth_seg_agent_shm.f（eth_seg_agent 可选 add-on）的 package import：在使用它的 package 或 module 内部写一行
// `include "eth_seg_agent_shm_import.svh"（eth_seg_agent.f 的 +incdir+./ 提供路径）。
// 只列 eth_seg_agent_shm.f 编译的 package；eth_seg_agent 主体的 import 在 eth_seg_agent_import.svh，shm_work 的 package 由使用者按需 import。
// 故意不加 include guard：每个需要的 package/module 各 include 一次。
import eth_seg_shm_pkg::*;
