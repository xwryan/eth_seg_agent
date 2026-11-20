// SHM 联仿测试顶层（每个 SimFlow 节点一份）：一条 100G link，CLIENT lb0_client 代替 DUT 发 TX，
// MAC lb0_mac 由 +lb0_mac.shm=1 接入 SHM；两端格式与帧数全部来自节点 plusarg。TX/RX 异步时钟，RX 较慢。
`timescale 1ns/1ps
module tb_shm;
  import uvm_pkg::*;
  import eth_seg_loopback_test_pkg::*;
  import eth_seg_shm_test_pkg::*;
  logic tx_clk = 0, rx_clk = 0;
  always #2ns tx_clk = ~tx_clk;
  always #3ns rx_clk = ~rx_clk;

  eth_loopback_link #(100, "lb0") lb0(tx_clk, rx_clk);

  initial begin
    #0;
    lb_case#(100)::configure(lb0.target.u_client.cfg, lb0.target.u_mac.cfg, 0, 0, 0);
    run_test("eth_seg_shm_test");
  end

  // 仿真时间看门狗，长于 Tcl end_test 的超时；墙钟由 SimFlow 节点超时兜底。
  initial begin
    #20ms;
    $fatal(1, "ETH_SHM_GLOBAL_TIMEOUT: test did not finish");
  end
endmodule
