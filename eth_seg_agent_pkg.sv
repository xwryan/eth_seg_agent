// eth_seg_agent 根入口：eth_seg_agent.f 唯一编译的源文件，按原编译顺序 include 本项目的全部源码（package、interface、module）；
// 路径相对仓库根目录，经 eth_seg_agent.f 的 +incdir+./ 解析。依赖项目须先经各自的 filelist 编译。
`ifndef ETH_SEG_AGENT_PKG_SV
`define ETH_SEG_AGENT_PKG_SV
`include "rtl/eth_seg_if.sv"
`include "src/eth_seg_types.sv"
`include "src/eth_seg_pkg.sv"
`include "checker/eth_seg_protocol_checker.sv"
`include "src/eth_net_packet_pkg.sv"
`include "src/eth_flow_pkg.sv"
`endif // ETH_SEG_AGENT_PKG_SV
