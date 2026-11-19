// loopback 测试公共 HDL：按方向复位控制、只含解析 net 的目标壳（按类型 bind CLIENT/MAC 两个 wrapper）及 link 封装。
// 须先于测试 package 编译；被 tb_loopback 与 tb_loopback_aip 共用。
`timescale 1ns/1ps
// 测试专用复位控制，避免给产品 interface 添加测试信号。
interface eth_loopback_control(input logic tx_clk, rx_clk);
  logic tx_rst_n = 0, rx_rst_n = 0;
endinterface

module eth_seg_loopback_target #(
  parameter int RATE = 100,
  parameter string PORT_NAME = "lbp",
  localparam int NUM_SEGMENTS = RATE/25,
  localparam int DATA_WIDTH = NUM_SEGMENTS*64
) (
  input wire i_clk_tx, i_clk_rx, i_tx_rst_n, i_rx_rst_n
);
  // 目标壳不驱动引脚，各方向只由领取驱动权的 wrapper 驱动。
  wire [DATA_WIDTH-1:0] i_tx_mac_data;
  wire i_tx_mac_valid;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_inframe;
  wire [NUM_SEGMENTS*3-1:0] i_tx_mac_eop_empty;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_error;
  wire [NUM_SEGMENTS-1:0] i_tx_mac_skip_crc;
  wire o_tx_mac_ready;
  wire [DATA_WIDTH-1:0] o_rx_mac_data;
  wire o_rx_mac_valid;
  wire [NUM_SEGMENTS-1:0] o_rx_mac_inframe;
  wire [NUM_SEGMENTS*3-1:0] o_rx_mac_eop_empty;
  wire [NUM_SEGMENTS-1:0] o_rx_mac_fcs_error;
  wire [NUM_SEGMENTS*2-1:0] o_rx_mac_error;
  wire [NUM_SEGMENTS*3-1:0] o_rx_mac_status_data;
endmodule

bind eth_seg_loopback_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_client"})
) u_client (.*);

bind eth_seg_loopback_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_mac"})
) u_mac (.*);

// link 内放复位控制，按 case 名发布给 test。
module eth_loopback_link #(parameter int RATE = 100, parameter string PORT_NAME = "lbp") (input logic tx_clk, rx_clk);
  import uvm_pkg::*;
  eth_loopback_control control(tx_clk, rx_clk);
  eth_seg_loopback_target #(.RATE(RATE), .PORT_NAME(PORT_NAME)) target(tx_clk, rx_clk, control.tx_rst_n, control.rx_rst_n);
  initial uvm_config_db#(virtual eth_loopback_control)::set(null, {"uvm_test_top.", PORT_NAME}, "control", control);
endmodule
