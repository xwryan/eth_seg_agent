// 可选报文适配层：把 net_packet 报文转成 agent 字节事务；编译顺序为 net_packet_pkg、eth_seg_pkg、本 package。
package eth_net_packet_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  `include "../seq_lib/eth_base_seq.sv"
endpackage
