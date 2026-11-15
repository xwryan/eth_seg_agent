// RX 驱动：把事务编码为 MAC 输出字节流，valid 节奏独立于 TX ready；负沿更新私有代理，valid 低时不消费字节，
// 包内状态跨气泡保留；EOP 在正沿真正采样后才通过 sent_ap 发布。
class eth_seg_rx_driver #(int RATE = 100) extends uvm_driver #(eth_seg_seq_item);
  `uvm_component_param_utils(eth_seg_rx_driver#(RATE))
  localparam int NUM_SEGMENTS = RATE/25;
  localparam int DATA_WIDTH = RATE/25*64;
  eth_seg_config#(RATE) cfg;
  uvm_analysis_port #(eth_seg_seq_item) sent_ap;
  int unsigned packets_sent = 0;
  eth_seg_seq_item pending[$], done_q[$], active;
  eth_seg_byte_queue_t encoded;
  int byte_ptr = 0, idle_left = 0, cycle_count = 0; // idle_left 单位是有效 segment。
  bit have_active = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  function bit is_idle();
    return pending.size() == 0 && !have_active && done_q.size() == 0;
  endfunction

  // 复位时丢弃预取副本，保证包中途复位后可以恢复。
  task prefetch_thread();
    eth_seg_seq_item req, cp;
    forever begin
      if (cfg == null || cfg.vif == null) begin #1ns; continue; end
      while (pending.size() >= cfg.max_pending && cfg.vif.i_rx_rst_n) @(posedge cfg.vif.i_clk_rx);
      seq_item_port.get_next_item(req);
      cp = new("rx_prefetch_copy"); cp.copy(req); seq_item_port.item_done();
      if (!cfg.vif.i_rx_rst_n) cp.aborted = 1;
      if (!cp.aborted) pending.push_back(cp);
    end
  endtask

  // valid 按 rx_valid_pattern 产生，traffic_load_pct 只在包间以 idle 段节流；一个有效周期最多 NUM_SEGMENTS 段，
  // EOP 后满足间隔的剩余段可承载下一包 SOP，没有下一包时必须清除这些段的边界标记。
  task drive_thread();
    bit send_valid;
    forever begin
      @(negedge cfg.vif.i_clk_rx);
      if (!cfg.vif.i_rx_rst_n) begin
        cfg.vif.drv_rx_valid <= 0; cfg.vif.drv_rx_data <= '0;
        cfg.vif.drv_rx_inframe <= '0; cfg.vif.drv_rx_eop_empty <= '0;
        cfg.vif.drv_rx_fcs_error <= '0; cfg.vif.drv_rx_error <= '0; cfg.vif.drv_rx_status_data <= '0;
        pending.delete(); done_q.delete(); active = null; have_active = 0; encoded.delete(); byte_ptr = 0; idle_left = 0; cycle_count = 0;
        continue;
      end
      cycle_count++;
      send_valid = 1;
      case (cfg.rx_valid_pattern)
        ETH_SEG_CONTINUOUS: send_valid = 1;
        ETH_SEG_PERIODIC: begin
          int period = cfg.rx_valid_high_cycles + cfg.rx_valid_low_cycles;
          send_valid = ((cycle_count-1) % period) < cfg.rx_valid_high_cycles;
        end
        ETH_SEG_RANDOM: send_valid = ($urandom_range(0,99) < cfg.rx_valid_high_pct);
      endcase
      // 无报文且无剩余间隔时才停 valid，否则末包间隔会一直挂到下一次发包。
      if (!have_active && pending.size() == 0 && idle_left == 0) send_valid = 0;
      cfg.vif.drv_rx_valid <= send_valid;
      if (!send_valid) continue;
      for (int s = 0; s < NUM_SEGMENTS; s++) begin
        if (!have_active && idle_left == 0 && pending.size() != 0) begin
          active = pending.pop_front();
          if (active.frame_bytes.size() < 9) begin `uvm_error("ETH_RX_LEN", "RX frame must contain at least 9 bytes"); active.aborted = 1; end
          eth_seg_codec::encode(active, cfg.preamble_passthrough, cfg.include_fcs, encoded);
          byte_ptr = 0; have_active = !active.aborted;
        end
        if (have_active) begin
          int remaining, nbytes;
          remaining = encoded.size() - byte_ptr; nbytes = (remaining > 8) ? 8 : remaining;
          for (int b = 0; b < 8; b++) cfg.vif.drv_rx_data[s*64+b*8 +: 8] <= (b<nbytes) ? encoded[byte_ptr+b] : 8'h00;
          cfg.vif.drv_rx_inframe[s] <= (remaining > 8);
          cfg.vif.drv_rx_eop_empty[s*3 +: 3] <= (remaining > 8) ? 3'd0 : (8-nbytes);
          cfg.vif.drv_rx_fcs_error[s] <= (remaining <= 8) ? active.rx_fcs_error : 1'b0;
          cfg.vif.drv_rx_error[s*2 +: 2] <= (remaining <= 8) ? active.rx_error : 2'b0;
          cfg.vif.drv_rx_status_data[s*3 +: 3] <= (remaining <= 8) ? active.rx_status : 3'b1;
          byte_ptr += nbytes;
          if (remaining <= 8) begin
            // sent_ap 与 RX monitor 的 frame_bytes 保持一致，包含启用的 FCS、但不包含前导。
            eth_seg_seq_item sent = new("rx_sent_copy");
            sent.copy(active);
            sent.frame_bytes = new[encoded.size() - (cfg.preamble_passthrough ? 8 : 0)];
            for (int k = 0; k < sent.frame_bytes.size(); k++)
              sent.frame_bytes[k] = encoded[k + (cfg.preamble_passthrough ? 8 : 0)];
            sent.fcs_present = cfg.include_fcs;
            done_q.push_back(sent);
            idle_left = cfg.gap_after_frame((encoded.size()+7)/8, active.gap_segments);
            active = null; have_active = 0; encoded.delete(); byte_ptr = 0;
          end
        end else begin
          // valid 对整拍生效：尾部空段若保留旧 inframe=1，接收方会看到未结束的幽灵包。
          cfg.vif.drv_rx_data[s*64 +: 64] <= '0;
          cfg.vif.drv_rx_inframe[s] <= 1'b0;
          cfg.vif.drv_rx_eop_empty[s*3 +: 3] <= '0;
          cfg.vif.drv_rx_fcs_error[s] <= 1'b0;
          cfg.vif.drv_rx_error[s*2 +: 2] <= '0;
          cfg.vif.drv_rx_status_data[s*3 +: 3] <= '0;
          if (idle_left > 0) idle_left--;
        end
      end
    end
  endtask

  task completion_thread();
    forever begin
      @(posedge cfg.vif.i_clk_rx);
      if (!cfg.vif.i_rx_rst_n) begin done_q.delete(); packets_sent = 0; continue; end
      if (cfg.vif.o_rx_mac_valid) begin
        for (int s=0;s<NUM_SEGMENTS;s++) if (!cfg.vif.o_rx_mac_inframe[s] && done_q.size()!=0) begin
          eth_seg_seq_item cp = done_q.pop_front(); cp.direction = ETH_SEG_RX; cp.end_time = $time; sent_ap.write(cp); packets_sent++;
        end
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    string reason; if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_RX_CFG", reason)
    cfg.vif.claim_rx(get_full_name());
    fork prefetch_thread(); drive_thread(); completion_thread(); join_none
    forever @(posedge cfg.vif.i_clk_rx);
  endtask

  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) cfg.vif.release_rx();
  endfunction
endclass
