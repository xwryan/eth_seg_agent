// F-Tile segmented MAC 接口：引脚、clocking 采样及按角色领取的唯一驱动权。
// 公共引脚为解析网络，无角色占用时驱动 Z，passive 或接真实 DUT 时不产生竞争。
interface eth_seg_if #(parameter int ETH_RATE_G = 100) (
  input logic i_clk_tx,
  input logic i_clk_rx,
  input logic i_tx_rst_n,
  input logic i_rx_rst_n
);
  localparam int NUM_SEGMENTS = ETH_RATE_G / 25;
  localparam int DATA_WIDTH = NUM_SEGMENTS * 64;

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

  logic [DATA_WIDTH-1:0] drv_tx_data = '0;
  logic drv_tx_valid = 0;
  logic [NUM_SEGMENTS-1:0] drv_tx_inframe = '0;
  logic [NUM_SEGMENTS*3-1:0] drv_tx_eop_empty = '0;
  logic [NUM_SEGMENTS-1:0] drv_tx_error = '0;
  logic [NUM_SEGMENTS-1:0] drv_tx_skip_crc = '0;
  logic [DATA_WIDTH-1:0] drv_rx_data = '0;
  logic drv_rx_valid = 0;
  logic [NUM_SEGMENTS-1:0] drv_rx_inframe = '0;
  logic [NUM_SEGMENTS*3-1:0] drv_rx_eop_empty = '0;
  logic [NUM_SEGMENTS-1:0] drv_rx_fcs_error = '0;
  logic [NUM_SEGMENTS*2-1:0] drv_rx_error = '0;
  logic [NUM_SEGMENTS*3-1:0] drv_rx_status_data = '0;
  logic drv_ready = 0;
  bit tx_drive_enabled = 0, rx_drive_enabled = 0, ready_drive_enabled = 0;
  string tx_owner, rx_owner, ready_owner;

  assign i_tx_mac_data = tx_drive_enabled ? drv_tx_data : 'z;
  assign i_tx_mac_valid = tx_drive_enabled ? drv_tx_valid : 'z;
  assign i_tx_mac_inframe = tx_drive_enabled ? drv_tx_inframe : 'z;
  assign i_tx_mac_eop_empty = tx_drive_enabled ? drv_tx_eop_empty : 'z;
  assign i_tx_mac_error = tx_drive_enabled ? drv_tx_error : 'z;
  assign i_tx_mac_skip_crc = tx_drive_enabled ? drv_tx_skip_crc : 'z;
  assign o_tx_mac_ready = ready_drive_enabled ? drv_ready : 'z;
  assign o_rx_mac_data = rx_drive_enabled ? drv_rx_data : 'z;
  assign o_rx_mac_valid = rx_drive_enabled ? drv_rx_valid : 'z;
  assign o_rx_mac_inframe = rx_drive_enabled ? drv_rx_inframe : 'z;
  assign o_rx_mac_eop_empty = rx_drive_enabled ? drv_rx_eop_empty : 'z;
  assign o_rx_mac_fcs_error = rx_drive_enabled ? drv_rx_fcs_error : 'z;
  assign o_rx_mac_error = rx_drive_enabled ? drv_rx_error : 'z;
  assign o_rx_mac_status_data = rx_drive_enabled ? drv_rx_status_data : 'z;

  clocking tx_cb @(posedge i_clk_tx);
    default input #1step;
    input i_tx_rst_n, i_tx_mac_data, i_tx_mac_valid, i_tx_mac_inframe;
    input i_tx_mac_eop_empty, i_tx_mac_error, i_tx_mac_skip_crc, o_tx_mac_ready;
  endclocking
  clocking rx_cb @(posedge i_clk_rx);
    default input #1step;
    input i_rx_rst_n, o_rx_mac_data, o_rx_mac_valid, o_rx_mac_inframe;
    input o_rx_mac_eop_empty, o_rx_mac_fcs_error, o_rx_mac_error, o_rx_mac_status_data;
  endclocking

  initial begin
    if (!(ETH_RATE_G inside {100, 200, 400}))
      $fatal(1, "eth_seg_if: ETH_RATE_G must be 100, 200 or 400");
  end

  // 重复领取即 fatal，防止两个 active 组件静默覆盖私有代理。
  function void claim_tx(input string owner = "anonymous");
    if (tx_drive_enabled) $fatal(1, "TX already claimed by %s", tx_owner);
    tx_owner = owner;
    tx_drive_enabled = 1;
  endfunction

  function void claim_rx(input string owner = "anonymous");
    if (rx_drive_enabled) $fatal(1, "RX already claimed by %s", rx_owner);
    rx_owner = owner;
    rx_drive_enabled = 1;
  endfunction

  // ready 与 RX 分开领取，以支持独立 ready 发生器或真实 DUT 接线。
  function void claim_ready(input string owner = "anonymous");
    if (ready_drive_enabled) $fatal(1, "ready already claimed by %s", ready_owner);
    ready_owner = owner;
    ready_drive_enabled = 1;
  endfunction

  function void release_tx();
    tx_drive_enabled = 0;
    tx_owner = "";
  endfunction

  function void release_rx();
    rx_drive_enabled = 0;
    rx_owner = "";
  endfunction

  function void release_ready();
    ready_drive_enabled = 0;
    ready_owner = "";
  endfunction
endinterface
