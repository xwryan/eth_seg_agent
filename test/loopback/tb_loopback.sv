// loopback 测试顶层：每条 link 由 bind 注入 CLIENT（代替 DUT 发 TX）与 MAC（loopback 回灌 RX）两个 wrapper，
// TX/RX 异步时钟（RX 较慢）、按 link 独立复位；lbn 只做 build 期拒绝，复位保持断言。
`timescale 1ns/1ps
module tb_loopback;
  import uvm_pkg::*;
  import eth_seg_loopback_test_pkg::*;
  logic tx_clk = 0, rx_clk = 0;
  always #2ns tx_clk = ~tx_clk;
  always #3ns rx_clk = ~rx_clk;

  eth_loopback_link #(100, "lbp") lbp(tx_clk, rx_clk);
  eth_loopback_link #(200, "lbf") lbf(tx_clk, rx_clk);
  eth_loopback_link #(400, "lbs") lbs(tx_clk, rx_clk);
  eth_loopback_link #(100, "lbt") lbt(tx_clk, rx_clk);
  eth_loopback_link #(200, "lbr") lbr(tx_clk, rx_clk);
  eth_loopback_link #(100, "lbo") lbo(tx_clk, rx_clk);
  eth_loopback_link #(100, "lbn") lbn(tx_clk, rx_clk);

  // #0 后 wrapper 已同步创建 cfg/agent：配置 MAC 角色与两端格式（client_fcs, mac_fcs, preamble）；
  // lbn 完全由 plusarg 配置，build 前挂上拒绝诊断的 catcher。
  initial begin
    #0;
    lb_case#(100)::configure(lbp.target.u_client.cfg, lbp.target.u_mac.cfg, 0, 0, 0);
    lb_case#(200)::configure(lbf.target.u_client.cfg, lbf.target.u_mac.cfg, 1, 1, 1);
    lbf.target.u_mac.cfg.loopback = 1;
    lb_case#(400)::configure(lbs.target.u_client.cfg, lbs.target.u_mac.cfg, 1, 0, 0);
    lb_case#(100)::configure(lbt.target.u_client.cfg, lbt.target.u_mac.cfg, 0, 1, 0);
    lb_case#(200)::configure(lbr.target.u_client.cfg, lbr.target.u_mac.cfg, 0, 0, 0);
    lbr.target.u_mac.cfg.loopback = 1;
    lb_case#(100)::configure(lbo.target.u_client.cfg, lbo.target.u_mac.cfg, 0, 0, 0);
    lbn.target.u_mac.cfg.enable_protocol_check = 0;
    reject_catcher = new("reject_catcher");
    reject_catcher.id = "ETH_AGENT_CFG";
    reject_catcher.severity = UVM_FATAL;
    reject_catcher.text = "loopback requires role ETH_SEG_MAC and is_active UVM_ACTIVE";
    uvm_report_cb::add(lbn.target.u_client.agt, reject_catcher);
    uvm_report_cb::add(lbn.target.u_mac.agt, reject_catcher);
    run_test("eth_seg_loopback_test");
  end

  // HDL 看门狗也覆盖 run_test 之前的卡死。
  initial begin
    #200us;
    $fatal(1, "ETH_LOOPBACK_GLOBAL_TIMEOUT: test did not finish");
  end
endmodule
