// TX 驱动：把字节事务切成并行 64-bit segment，ready→valid 固定两拍延迟。
// prefetch 深拷贝后尽早 item_done；ready 在正沿经 clocking 采样，驱动在负沿更新私有代理，正沿采到 EOP 后才发布 sent_ap。
class eth_seg_tx_driver #(int RATE = 100) extends uvm_driver #(eth_seg_seq_item);
  `uvm_component_param_utils(eth_seg_tx_driver#(RATE))
  localparam int NUM_SEGMENTS = RATE/25;
  localparam int DATA_WIDTH = RATE/25*64;
  eth_seg_config#(RATE) cfg;
  uvm_analysis_port #(eth_seg_seq_item) sent_ap;
  int unsigned packets_sent = 0;
  eth_seg_seq_item pending[$], done_q[$];
  eth_seg_seq_item active;
  eth_seg_byte_queue_t encoded;
  int byte_ptr = 0;
  int idle_left = 0; // 尚需发送的有效 idle segment 数，不是时钟周期数。
  bit have_active = 0;
  bit ready_d1 = 0, ready_d2 = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    sent_ap = new("sent_ap", this);
  endfunction

  function bit is_idle();
    return pending.size() == 0 && !have_active && done_q.size() == 0;
  endfunction

  // 队列达到 max_pending 时反压 sequence；复位期间丢弃副本，避免复位解除后续传旧包。
  task prefetch_thread();
    eth_seg_seq_item req, cp;
    forever begin
      if (cfg == null || cfg.vif == null) begin #1ns; continue; end
      while (pending.size() >= cfg.max_pending && cfg.vif.i_tx_rst_n) @(posedge cfg.vif.i_clk_tx);
      seq_item_port.get_next_item(req);
      cp = new("tx_prefetch_copy");
      cp.copy(req);
      seq_item_port.item_done();
      if (!cfg.vif.i_tx_rst_n) cp.aborted = 1;
      if (!cp.aborted) pending.push_back(cp);
    end
  endtask

  // 正沿 t 更新 d2=ready[t-1]，负沿驱动、正沿 t+1 被采样，即固定两拍；统一正沿采样隔离 DUT 在正/负沿更新输出的差别。
  // 使用 input #1step 的 clocking 值，避免与 DUT 同沿 NBA 输出产生调度竞争。
  task sample_ready_thread();
    forever begin
      @(cfg.vif.tx_cb);
      if (!cfg.vif.tx_cb.i_tx_rst_n) begin ready_d1 = 0; ready_d2 = 0; end
      else begin ready_d2 = ready_d1; ready_d1 = cfg.vif.tx_cb.o_tx_mac_ready; end
    end
  endtask

  // valid 只由两拍 ready 历史决定，valid=0 时 data 与全部边带保持上一次值；EOP 后满足包间隔即可在同一拍开始下一包。
  task drive_thread();
    bit next_valid;
    forever begin
      @(negedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin
        cfg.vif.drv_tx_valid <= 0;
        cfg.vif.drv_tx_data <= '0;
        cfg.vif.drv_tx_inframe <= '0;
        cfg.vif.drv_tx_eop_empty <= '0;
        cfg.vif.drv_tx_error <= '0;
        cfg.vif.drv_tx_skip_crc <= '0;
        active = null; have_active = 0; byte_ptr = 0;
        idle_left = 0;
        encoded.delete(); done_q.delete(); pending.delete();
        continue;
      end
      next_valid = ready_d2;
      cfg.vif.drv_tx_valid <= next_valid;
      if (!next_valid) continue;
      cfg.vif.drv_tx_data <= cfg.vif.drv_tx_data;
      cfg.vif.drv_tx_inframe <= cfg.vif.drv_tx_inframe;
      cfg.vif.drv_tx_eop_empty <= cfg.vif.drv_tx_eop_empty;
      cfg.vif.drv_tx_error <= cfg.vif.drv_tx_error;
      cfg.vif.drv_tx_skip_crc <= cfg.vif.drv_tx_skip_crc;
      for (int s = 0; s < NUM_SEGMENTS; s++) begin
        if (!have_active && idle_left == 0 && pending.size() != 0) begin
          active = pending.pop_front();
          if (active.frame_bytes.size() < 9) begin
            `uvm_error("ETH_TX_LEN", "TX frame must contain at least 9 bytes")
            active.aborted = 1;
          end
          eth_seg_codec::encode(active, cfg.preamble_passthrough, cfg.include_fcs, encoded);
          byte_ptr = 0; have_active = !active.aborted;
        end
        if (have_active) begin
          int remaining, nbytes;
          remaining = encoded.size() - byte_ptr;
          nbytes = (remaining > 8) ? 8 : remaining;
          for (int b = 0; b < 8; b++)
            cfg.vif.drv_tx_data[s*64 + b*8 +: 8] <= (b < nbytes) ? encoded[byte_ptr+b] : 8'h00;
          cfg.vif.drv_tx_inframe[s] <= (remaining > 8);
          cfg.vif.drv_tx_eop_empty[s*3 +: 3] <= (remaining > 8) ? 3'd0 : (8-nbytes);
          cfg.vif.drv_tx_error[s] <= (remaining <= 8) ? active.inject_error : 1'b0;
          cfg.vif.drv_tx_skip_crc[s] <= cfg.include_fcs;
          byte_ptr += nbytes;
          if (remaining <= 8) begin
            // sent_ap 必须与 monitor 可见字节一致（含自动 FCS、不含前导），因此发布编码结果而非原始 sequence 副本。
            eth_seg_seq_item sent = new("tx_sent_copy");
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
          // valid 仍由 ready 历史决定；包间节流以空闲 segment 表示，绝不改写 valid。
          cfg.vif.drv_tx_inframe[s] <= 1'b0;
          cfg.vif.drv_tx_eop_empty[s*3 +: 3] <= 3'd0;
          cfg.vif.drv_tx_error[s] <= 1'b0;
          cfg.vif.drv_tx_skip_crc[s] <= 1'b0;
          if (idle_left > 0) idle_left--;
        end
      end
    end
  endtask

  // 在 EOP 所在正沿按真实 valid/inframe 发布已采样的报文；复位清空待发布队列，避免旧包计入新一轮。
  task completion_thread();
    forever begin
      @(posedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin done_q.delete(); packets_sent = 0; continue; end
      if (cfg.vif.i_tx_mac_valid) begin
        for (int s = 0; s < NUM_SEGMENTS; s++) begin
          if (!cfg.vif.i_tx_mac_inframe[s] && done_q.size() != 0) begin
            eth_seg_seq_item cp = done_q.pop_front();
            cp.direction = ETH_SEG_TX;
            cp.end_time = $time;
            sent_ap.write(cp);
            packets_sent++;
          end
        end
      end
    end
  endtask

  task run_phase(uvm_phase phase);
    string reason;
    if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_TX_CFG", reason)
    cfg.vif.claim_tx(get_full_name());
    fork
      prefetch_thread();
      sample_ready_thread();
      drive_thread();
      completion_thread();
    join_none
    forever @(posedge cfg.vif.i_clk_tx);
  endtask

  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) cfg.vif.release_tx();
  endfunction
endclass
