// hub/SCB 无引脚单元测试顶层：只负责启动与总超时，不依赖 net_packet/AIP。
`timescale 1ns/1ps
module tb_hub;
  import uvm_pkg::*;
  import eth_seg_hub_test_pkg::*;
  initial run_test("eth_seg_hub_test");
  initial begin
    #100us;
    $fatal(1, "ETH_HUB_GLOBAL_TIMEOUT");
  end
endmodule
