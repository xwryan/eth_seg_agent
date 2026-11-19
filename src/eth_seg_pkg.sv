// VIP 顶层 package，按依赖顺序 include 全部组件；interface 需先单独编译，不可拆成按 RATE 的多个 package。
// cfg 读参直接用 aip_core 宏，aip_core_pkg 须先编译。
package eth_seg_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_types_pkg::*;
  `include "uvm_macros.svh"

  `include "eth_seg_seq_item.sv"
  `include "eth_seg_codec.sv"
  `include "eth_seg_config.sv"
  `include "eth_seg_monitor_hub.sv"
  `include "eth_seg_sequencer.sv"
  `include "eth_seg_tx_driver.sv"
  `include "eth_seg_rx_driver.sv"
  `include "eth_seg_ready_driver.sv"
  `include "eth_seg_tx_monitor.sv"
  `include "eth_seg_rx_monitor.sv"
  `include "eth_seg_loopback.sv"
  `include "eth_seg_scoreboard.sv"
  `include "eth_seg_coverage.sv"
  `include "eth_seg_agent.sv"
  `include "eth_seg_env.sv"
  `include "../seq_lib/eth_seg_base_seq.sv"
  `include "../seq_lib/eth_seg_frame_seq.sv"
endpackage
