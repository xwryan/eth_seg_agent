// 可选流控适配层：在 flow_control_pkg 与 eth_net_packet_pkg 之上声明 eth_flow_seq，基础 agent 不反向依赖本层。
package eth_flow_pkg;
  timeunit 1ns;
  timeprecision 1fs;

  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  import flow_control_pkg::*;
  `include "uvm_macros.svh"

  // 与 flow_control_pkg 同为 1ns/1fs，get_interval 返回的 ns 数值可直接参与预算计算。
  `include "../seq_lib/eth_flow_seq.sv"
endpackage
