// RX 引脚 monitor：只在 o_rx_mac_valid=1 时消费 segment，invalid 拍忽略数据与边带，当前包可跨任意气泡保留。
// EOP 段提取 empty/fcs_error/error/status_data；CRC 错误随事务传播而不报 uvm_error，复位中断的包计入 aborted_packets。
class eth_seg_rx_monitor #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_rx_monitor#(RATE))

  eth_seg_config#(RATE) cfg;
  virtual eth_seg_if#(RATE) vif;
  uvm_analysis_port#(eth_seg_seq_item) item_collected_port;
  uvm_analysis_port#(bit) reset_state_port;
  bit reset_observed, previous_reset;
  int unsigned packets_seen, aborted_packets, valid_cycles, invalid_cycles;
  int unsigned idle_segments, data_segments, bytes_seen, same_cycle_boundaries;

  bit in_packet;
  int segment_index;
  eth_seg_byte_queue_t packet_bytes;
  eth_seg_seq_item packet_item;

  function new(string name = "eth_seg_rx_monitor", uvm_component parent = null);
    super.new(name, parent);
    item_collected_port = new("item_collected_port", this);
    reset_state_port = new("reset_state_port", this);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    if (cfg == null) void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg != null) vif = cfg.vif;
    if (vif == null) `uvm_fatal("ETH_SEG_RX_MON_CFG", "RX monitor virtual interface is null")
  endfunction

  function bit is_idle();
    return !in_packet && packet_bytes.size() == 0;
  endfunction

  // segment 内低字节在前；只在有效拍调用。
  function void append_segment(input int seg, input int nbytes);
    for (int b = 0; b < nbytes; b++)
      packet_bytes.push_back(vif.rx_cb.o_rx_mac_data[seg*64 + b*8 +: 8]);
    bytes_seen += nbytes;
  endfunction

  task automatic finish_packet(input int seg, input int empty);
    string reason;
    bit ok;
    packet_item.eop_segment = segment_index;
    packet_item.empty_bytes = empty;
    packet_item.rx_fcs_error = vif.rx_cb.o_rx_mac_fcs_error[seg];
    packet_item.rx_error = vif.rx_cb.o_rx_mac_error[seg*2 +: 2];
    packet_item.rx_status = vif.rx_cb.o_rx_mac_status_data[seg*3 +: 3];
    packet_item.direction = ETH_SEG_RX;
    ok = eth_seg_codec::decode(packet_bytes, cfg.preamble_passthrough,
                               cfg.include_fcs, packet_item, reason);
    if (!ok) begin
      `uvm_error("ETH_SEG_RX_MON_FORMAT", $sformatf("ETH_SEG_RX_FORMAT: %s", reason))
      packet_item.aborted = 1;
    end
    packet_item.end_time = $time;
    item_collected_port.write(packet_item);
    packets_seen++;
    packet_item = null;
    packet_bytes.delete();
    in_packet = 0;
  endtask

  task run_phase(uvm_phase phase);
    bit ended_this_cycle;
    forever begin
      @(vif.rx_cb);
      // 首次同步及复位边沿时通知（先清 hub，再消费本拍数据）；X 复位由接口检查，这里只把确定的低电平视为断言。
      if (!reset_observed || previous_reset != (vif.rx_cb.i_rx_rst_n === 1'b0)) begin
        reset_observed = 1;
        previous_reset = (vif.rx_cb.i_rx_rst_n === 1'b0);
        reset_state_port.write(previous_reset);
      end
      if (!vif.rx_cb.i_rx_rst_n) begin
        if (in_packet) aborted_packets++;
        in_packet = 0;
        packet_bytes.delete();
        packet_item = null;
        segment_index = 0;
        continue;
      end
      if (!vif.rx_cb.o_rx_mac_valid) begin
        invalid_cycles++;
        continue;
      end
      valid_cycles++;
      ended_this_cycle = 0;
      for (int s = 0; s < RATE/25; s++) begin
        bit seg_inframe = vif.rx_cb.o_rx_mac_inframe[s];
        int empty = vif.rx_cb.o_rx_mac_eop_empty[s*3 +: 3];
        int nbytes;
        if (!in_packet && !seg_inframe) begin
          idle_segments++;
          continue;
        end
        if (!in_packet) begin
          in_packet = 1;
          packet_bytes.delete();
          packet_item = new("rx_mon_item");
          packet_item.start_segment = segment_index;
          packet_item.start_time = $time;
          if (ended_this_cycle) same_cycle_boundaries++;
        end
        data_segments++;
        nbytes = seg_inframe ? 8 : (8 - empty);
        if (!seg_inframe && (empty > 7 || nbytes < 1)) begin
          `uvm_error("ETH_SEG_RX_MON_EMPTY", "ETH_SEG_RX_EMPTY_INVALID: EOP empty must be 0..7")
          nbytes = 1;
        end
        append_segment(s, nbytes);
        if (!seg_inframe) begin
          finish_packet(s, empty);
          ended_this_cycle = 1;
        end
        segment_index++;
      end
    end
  endtask
endclass
