// loopback Tcl 测试顶层：一条 100G link，CLIENT lb0_client 由 Tcl 命令发 TX，MAC lb0_mac 的 loopback 由 Tcl set_param 开关。
`timescale 1ns/1ps
module tb_loopback_aip;
  import uvm_pkg::*;
  import eth_seg_loopback_test_pkg::*;
  import eth_seg_loopback_aip_test_pkg::*;
  logic tx_clk = 0, rx_clk = 0;
  always #2ns tx_clk = ~tx_clk;
  always #3ns rx_clk = ~rx_clk;

  eth_loopback_link #(100, "lb0") lb0(tx_clk, rx_clk);

  initial begin
    #0;
    lb_case#(100)::configure(lb0.target.u_client.cfg, lb0.target.u_mac.cfg, 0, 0, 0);
    run_test("eth_seg_loopback_aip_test");
  end

  // 看门狗：bridge、Tcl 或数据通路卡住时明确失败。
  initial begin
    #50us;
    $fatal(1, "ETH_LOOPBACK_AIP_GLOBAL_TIMEOUT: Tcl test did not finish");
  end
endmodule
