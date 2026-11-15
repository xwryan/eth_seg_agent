// 时序测试控制接口：独立 TX/RX 复位与 DUT ready 请求，不给产品 eth_seg_if 添加测试信号。
interface eth_timing_control(input logic tx_clk, rx_clk);
  logic tx_rst_n = 0, rx_rst_n = 0;
  logic ready_request = 0;
endinterface
