// SHM 联仿测试顶层（每个 SimFlow 节点一份）：每条 link 一对 bind agent，CLIENT <link>_client 代替 DUT 发 TX，
// MAC <link>_mac 由 +<link>_mac.shm=1 接入 SHM；两端格式与帧数全部来自节点 plusarg。TX/RX 异步时钟，RX 较慢。
// 单链路用例只用 lb0；多链路用例用 eth0..eth3（100G）与 eth4（400G，混合速率）。没置 shm 的 link 保持复位、空闲。
`timescale 1ns/1ps
module tb_shm;
  import uvm_pkg::*;
  import eth_seg_loopback_test_pkg::*;
  import eth_seg_shm_test_pkg::*;
  logic tx_clk = 0, rx_clk = 0;
  always #2ns tx_clk = ~tx_clk;
  always #3ns rx_clk = ~rx_clk;

  eth_loopback_link #(100, "lb0") lb0(tx_clk, rx_clk);
  eth_loopback_link #(100, "eth0") eth0(tx_clk, rx_clk);
  eth_loopback_link #(100, "eth1") eth1(tx_clk, rx_clk);
  eth_loopback_link #(100, "eth2") eth2(tx_clk, rx_clk);
  eth_loopback_link #(100, "eth3") eth3(tx_clk, rx_clk);
  eth_loopback_link #(400, "eth4") eth4(tx_clk, rx_clk);

  initial begin
    #0;
    lb_case#(100)::configure(lb0.target.u_client.cfg, lb0.target.u_mac.cfg, 0, 0, 0);
    lb_case#(100)::configure(eth0.target.u_client.cfg, eth0.target.u_mac.cfg, 0, 0, 0);
    lb_case#(100)::configure(eth1.target.u_client.cfg, eth1.target.u_mac.cfg, 0, 0, 0);
    lb_case#(100)::configure(eth2.target.u_client.cfg, eth2.target.u_mac.cfg, 0, 0, 0);
    lb_case#(100)::configure(eth3.target.u_client.cfg, eth3.target.u_mac.cfg, 0, 0, 0);
    lb_case#(400)::configure(eth4.target.u_client.cfg, eth4.target.u_mac.cfg, 0, 0, 0);
    run_test("eth_seg_shm_test");
  end

  // 仿真时间看门狗，长于 Tcl end_test 的超时；墙钟由 SimFlow 节点超时兜底。
  initial begin
    #20ms;
    $fatal(1, "ETH_SHM_GLOBAL_TIMEOUT: test did not finish");
  end
endmodule
