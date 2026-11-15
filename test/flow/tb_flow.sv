// test/flow HDL 夹具：十二条 link 由流控测试借用，顶层拥有时钟/复位。
// 依赖 eth_flow_test_pkg/interface/checker；本层拥有时钟复位和 interface，
// UVM case 只借用 vif，pin checker 独立验证 ready 延迟与帧边带。
`timescale 1ns/1fs
module eth_flow_link #(parameter int RATE = 100, MODE = 0)(input logic clk, rst_n);
  import uvm_pkg::*;
  eth_seg_if#(RATE) vif(clk, clk, rst_n, rst_n);

  eth_seg_protocol_checker#(.RATE(RATE)) pin_check (
    .i_clk_tx(clk), .i_clk_rx(clk), .i_tx_rst_n(rst_n), .i_rx_rst_n(rst_n),
    .i_tx_mac_data(vif.i_tx_mac_data), .i_tx_mac_valid(vif.i_tx_mac_valid),
    .i_tx_mac_inframe(vif.i_tx_mac_inframe), .i_tx_mac_eop_empty(vif.i_tx_mac_eop_empty),
    .i_tx_mac_error(vif.i_tx_mac_error), .i_tx_mac_skip_crc(vif.i_tx_mac_skip_crc),
    .o_tx_mac_ready(vif.o_tx_mac_ready), .o_rx_mac_data(vif.o_rx_mac_data),
    .o_rx_mac_valid(vif.o_rx_mac_valid), .o_rx_mac_inframe(vif.o_rx_mac_inframe),
    .o_rx_mac_eop_empty(vif.o_rx_mac_eop_empty), .o_rx_mac_fcs_error(vif.o_rx_mac_fcs_error),
    .o_rx_mac_error(vif.o_rx_mac_error), .o_rx_mac_status_data(vif.o_rx_mac_status_data)
  );

  // time-0 同步发布，顶层 #0 后的 UVM build 才读取这些句柄。
  initial uvm_config_db#(virtual eth_seg_if#(RATE))::set(
    null, $sformatf("uvm_test_top.r%0d_m%0d", RATE, MODE), "vif", vif);
endmodule

// 采用绝对理想沿时间避免逐半周期取整造成频偏；不依赖 AIP 即可验证核心适配。
module tb_flow;
  import uvm_pkg::*;
  import eth_flow_test_pkg::*;
  logic clk = 0, rst_n = 0;

  initial begin
    realtime ideal_ns = 0.0;
    real clock_hz = 415039062.5;
    void'($value$plusargs("FLOW_CLOCK_HZ=%f", clock_hz));
    forever begin
      ideal_ns += 1.0e9 / (2.0 * clock_hz);
      #(ideal_ns - $realtime) clk = ~clk;
    end
  end
  initial #41ns rst_n = 1;

  for (genvar m = 0; m < 4; m++) begin : formats
    eth_flow_link#(100, m) link100(clk, rst_n);
    eth_flow_link#(200, m) link200(clk, rst_n);
    eth_flow_link#(400, m) link400(clk, rst_n);
  end

  initial begin #0; run_test("eth_flow_test"); end

  // 包括模型错误造成的无限等待；完成标记和零错误报告仍由日志检查器独立核对。
  initial begin #1ms; $fatal(1, "ETH_FLOW_GLOBAL_TIMEOUT"); end
endmodule
