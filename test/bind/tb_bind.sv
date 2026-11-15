// bind 测试顶层：仅含解析 net 的目标壳，按模块类型 bind 注入 wrapper；
// 四个 IP 覆盖三种速率，验证 supply 接管、默认 cfg 和 #0 启动。
`timescale 1ns/1ps
module eth_seg_bind_target #(
  parameter int RATE = 100,
  parameter string PORT_NAME = "case100",
  parameter bit OVERRIDE = 1,
  localparam int NUM_SEGMENTS = RATE/25,
  localparam int DATA_WIDTH = NUM_SEGMENTS*64
) (
  input wire i_clk_tx, i_clk_rx, i_tx_rst_n, i_rx_rst_n
);
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

  // 原驱动故意保持全 1，与 agent 的空闲值和数据相冲突，供 supply 接管验证。
  // 关闭 OVERRIDE 时原驱动为 Z，wrapper 成为该方向的唯一驱动。
  assign i_tx_mac_data = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_valid = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_inframe = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_eop_empty = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_error = OVERRIDE ? '1 : 'z;
  assign i_tx_mac_skip_crc = OVERRIDE ? '1 : 'z;
  assign o_tx_mac_ready = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_data = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_valid = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_inframe = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_eop_empty = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_fcs_error = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_error = OVERRIDE ? '1 : 'z;
  assign o_rx_mac_status_data = OVERRIDE ? '1 : 'z;

  // 比较实际解析的全部引脚与各 wrapper interface（含 invalid 拍）：漏连、错位、passive 反驱或未接管原驱动都会暴露。
  localparam int VIEW_WIDTH = 2*DATA_WIDTH + 16*NUM_SEGMENTS + 3;
  wire [VIEW_WIDTH-1:0] pins_view = {
    i_tx_mac_data,
    i_tx_mac_valid,
    i_tx_mac_inframe,
    i_tx_mac_eop_empty,
    i_tx_mac_error,
    i_tx_mac_skip_crc,
    o_tx_mac_ready,
    o_rx_mac_data,
    o_rx_mac_valid,
    o_rx_mac_inframe,
    o_rx_mac_eop_empty,
    o_rx_mac_fcs_error,
    o_rx_mac_error,
    o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] client_view = {
    u_client.u_eth_if.i_tx_mac_data,
    u_client.u_eth_if.i_tx_mac_valid,
    u_client.u_eth_if.i_tx_mac_inframe,
    u_client.u_eth_if.i_tx_mac_eop_empty,
    u_client.u_eth_if.i_tx_mac_error,
    u_client.u_eth_if.i_tx_mac_skip_crc,
    u_client.u_eth_if.o_tx_mac_ready,
    u_client.u_eth_if.o_rx_mac_data,
    u_client.u_eth_if.o_rx_mac_valid,
    u_client.u_eth_if.o_rx_mac_inframe,
    u_client.u_eth_if.o_rx_mac_eop_empty,
    u_client.u_eth_if.o_rx_mac_fcs_error,
    u_client.u_eth_if.o_rx_mac_error,
    u_client.u_eth_if.o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] mac_view = {
    u_mac.u_eth_if.i_tx_mac_data,
    u_mac.u_eth_if.i_tx_mac_valid,
    u_mac.u_eth_if.i_tx_mac_inframe,
    u_mac.u_eth_if.i_tx_mac_eop_empty,
    u_mac.u_eth_if.i_tx_mac_error,
    u_mac.u_eth_if.i_tx_mac_skip_crc,
    u_mac.u_eth_if.o_tx_mac_ready,
    u_mac.u_eth_if.o_rx_mac_data,
    u_mac.u_eth_if.o_rx_mac_valid,
    u_mac.u_eth_if.o_rx_mac_inframe,
    u_mac.u_eth_if.o_rx_mac_eop_empty,
    u_mac.u_eth_if.o_rx_mac_fcs_error,
    u_mac.u_eth_if.o_rx_mac_error,
    u_mac.u_eth_if.o_rx_mac_status_data
  };
  wire [VIEW_WIDTH-1:0] observer_view = {
    u_observer.u_eth_if.i_tx_mac_data,
    u_observer.u_eth_if.i_tx_mac_valid,
    u_observer.u_eth_if.i_tx_mac_inframe,
    u_observer.u_eth_if.i_tx_mac_eop_empty,
    u_observer.u_eth_if.i_tx_mac_error,
    u_observer.u_eth_if.i_tx_mac_skip_crc,
    u_observer.u_eth_if.o_tx_mac_ready,
    u_observer.u_eth_if.o_rx_mac_data,
    u_observer.u_eth_if.o_rx_mac_valid,
    u_observer.u_eth_if.o_rx_mac_inframe,
    u_observer.u_eth_if.o_rx_mac_eop_empty,
    u_observer.u_eth_if.o_rx_mac_fcs_error,
    u_observer.u_eth_if.o_rx_mac_error,
    u_observer.u_eth_if.o_rx_mac_status_data
  };
  int pin_checks = 0;

  // 延后一个精度单位检查，避开同一时刻其它时钟负沿的 NBA/assign 收敛；reset 内允许 time-0 尚未领取驱动权。
  always @(posedge i_clk_tx) begin
    if (i_tx_rst_n && i_rx_rst_n) begin
      #1ps;
      if ($isunknown(pins_view) || pins_view !== client_view ||
          pins_view !== mac_view || pins_view !== observer_view)
        $fatal(1, "ETH_BIND_PIN_READBACK: RATE=%0d resolved pins differ from interface", RATE);
      pin_checks++;
    end
  end
endmodule

// 按模块类型 bind，四个实例都会绑定；只传 RATE 与名字，observer 留空以测试按层次自动命名。
bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_client"})
) u_client (.*);

bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE), .AGENT_NAME({PORT_NAME, "_mac"})
) u_mac (.*);

bind eth_seg_bind_target eth_seg_bind_wrapper #(
  .RATE(RATE)
) u_observer (.*);

// 顶层统一调用 run_test，wrapper 内不得各自调用。
module tb_bind;
  import uvm_pkg::*;
  import eth_seg_bind_test_pkg::*;
  logic clk_tx = 0, clk_rx = 0, rst_n = 0;

  always #2ns clk_tx = ~clk_tx;
  always #3ns clk_rx = ~clk_rx;

  eth_seg_bind_target #(.RATE(100), .PORT_NAME("case100"), .OVERRIDE(1)) link100
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(200), .PORT_NAME("case200"), .OVERRIDE(0)) link200
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(400), .PORT_NAME("case400"), .OVERRIDE(1)) link400
    (clk_tx, clk_rx, rst_n, rst_n);
  eth_seg_bind_target #(.RATE(100), .PORT_NAME("case100b"), .OVERRIDE(1)) link100b
    (clk_tx, clk_rx, rst_n, rst_n);

  // 41 ns 避开两种时钟的正负沿，给所有 root driver 留出多个完整复位周期。
  initial #41ns rst_n = 1;

  initial begin
    // wrapper 在 Active 区创建 cfg/agent，#0 进入 Inactive 区后再取句柄；sequencer 要到 run_test 的 build/connect 才创建。
    #0;
    bind_rate_case#(100)::configure(link100.u_client.cfg, link100.u_mac.cfg, link100.u_observer.cfg);
    bind_rate_case#(200)::configure(link200.u_client.cfg, link200.u_mac.cfg, link200.u_observer.cfg);
    bind_rate_case#(400)::configure(link400.u_client.cfg, link400.u_mac.cfg, link400.u_observer.cfg);
    bind_rate_case#(100)::configure(link100b.u_client.cfg, link100b.u_mac.cfg, link100b.u_observer.cfg);
    uvm_config_db#(string)::set(null, "uvm_test_top.case100", "observer_name", link100.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case200", "observer_name", link200.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case400", "observer_name", link400.u_observer.resolved_name);
    uvm_config_db#(string)::set(null, "uvm_test_top.case100b", "observer_name", link100b.u_observer.resolved_name);
    run_test("eth_seg_bind_test");
  end

  // HDL watchdog 也覆盖 run_test 之前的初始化卡死。
  initial begin
    #25us;
    $fatal(1, "ETH_BIND_STARTUP_TIMEOUT: test did not finish");
  end
endmodule
