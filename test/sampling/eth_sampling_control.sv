// 采样测试专用的复位控制接口，避免给产品 interface 添加测试信号。
interface eth_sampling_control(input logic clk);
  logic tx_rst_n = 0;
  logic rx_rst_n = 0;
endinterface
