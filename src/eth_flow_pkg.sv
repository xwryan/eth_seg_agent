// src 可选流控适配层：依赖 eth_net_packet_pkg 和外部 flow_control_pkg。
// 流控类型由先编译的 flow_control_pkg 统一拥有，本层 import 后只声明 Ethernet 序列。
// sequence 持有模型及小数预算，基础 agent/net_packet 不反向依赖本层。
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
