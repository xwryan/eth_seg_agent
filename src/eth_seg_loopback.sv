// TX→RX 回环：MAC active agent 把 TX monitor 的整帧按序、原样经自身 sequencer 交给 rx_driver（store-and-forward）。
// 队列上限 cfg.max_pending，满即 UVM_ERROR 且该帧不回环；任一方向复位断言清空队列，复位期间到达的帧同样丢弃。
// 开启期间 TX 帧带 EOP error 或显式 FCS 错误时报 ETH_LOOPBACK_TX_ERROR（帧仍原样处理），故意注错的测试自行降级。
`uvm_analysis_imp_decl(_loopback_tx)
`uvm_analysis_imp_decl(_loopback_sent)
`uvm_analysis_imp_decl(_loopback_reset)

typedef class eth_seg_loopback;

// 常驻 sequence：有帧时才申请仲裁，每次一整帧，与用户 RX sequence 在帧边界交错；
// grant 后才出队，等待仲裁（如用户 sequence 持锁）期间被复位清掉的帧不会再送出。
class eth_seg_loopback_seq #(int RATE = 100) extends uvm_sequence #(eth_seg_seq_item);
  `uvm_object_param_utils(eth_seg_loopback_seq#(RATE))
  eth_seg_loopback#(RATE) lb;

  function new(string name = "eth_seg_loopback_seq");
    super.new(name);
  endfunction

  task body();
    eth_seg_seq_item item;
    forever begin
      lb.wait_frame();
      item = eth_seg_seq_item::type_id::create("loopback_frame");
      start_item(item);
      lb.take_frame(item);
      finish_item(item);
    end
  endtask
endclass

class eth_seg_loopback #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_loopback#(RATE))

  eth_seg_config#(RATE) cfg;
  eth_seg_sequencer sequencer;
  string param_path; // aip 参数路径，即 agent 登记名
  uvm_analysis_imp_loopback_tx#(eth_seg_seq_item, eth_seg_loopback#(RATE)) tx_export;
  uvm_analysis_imp_loopback_sent#(eth_seg_seq_item, eth_seg_loopback#(RATE)) sent_export;
  uvm_analysis_imp_loopback_reset#(eth_seg_reset_notice_t, eth_seg_loopback#(RATE)) reset_export;
  // looped：RX 正沿采到 EOP 的回环帧；flushed：复位清除；dropped：溢出、过短或 TX 格式错误；tx_errors：开启期间的带错 TX 帧。
  int unsigned looped_frames, flushed_frames, dropped_frames, tx_errors;
  protected int unsigned tx_index;     // TX monitor 发布的帧序号（从 0 计，不随开关和复位清零）
  protected eth_seg_seq_item frames[$];
  protected int unsigned in_flight;    // 已交给 rx_driver、尚未完成
  protected bit in_reset[2] = '{1, 1}; // 收到 hub 首个复位通知前按复位处理
  protected bit enabled_seen;

  function new(string name, uvm_component parent);
    super.new(name, parent);
    tx_export = new("tx_export", this);
    sent_export = new("sent_export", this);
    reset_export = new("reset_export", this);
  endfunction

  // 队列中与已交 driver 未完成的回环帧数。
  function int unsigned pending();
    return frames.size() + in_flight;
  endfunction

  // 只表示回环通路已空；结束测试仍须核对 RX monitor 数量。
  function bit is_idle();
    return pending() == 0;
  endfunction

  // TX→RX 原样回环：从 DA 起复制字节（前导由两侧 preamble_passthrough 处理）；TX 带 FCS（skip_crc）时 RX include_fcs
  // 保留原四字节（坏 CRC 也原样）、否则剥离，TX 无 FCS 时 RX include_fcs 由 codec 补正确 CRC。不翻转 CRC；
  // rx_fcs_error 同接收端 MAC，只反映帧自带 FCS 的校验结果，TX EOP error 不改写 RX 字段，由 ETH_LOOPBACK_TX_ERROR 报告。
  function eth_seg_seq_item to_rx(eth_seg_seq_item tx);
    eth_seg_seq_item rx;
    int keep;
    rx = eth_seg_seq_item::type_id::create("loopback_frame");
    keep = tx.frame_bytes.size() - ((tx.fcs_present && !cfg.include_fcs) ? 4 : 0);
    rx.frame_bytes = new[(keep > 0) ? keep : 0];
    foreach (rx.frame_bytes[i]) rx.frame_bytes[i] = tx.frame_bytes[i];
    rx.fcs_present = tx.fcs_present && cfg.include_fcs;
    rx.rx_fcs_error = tx.fcs_present && !tx.fcs_ok;
    rx.direction = ETH_SEG_RX;
    return rx;
  endfunction

  // 带错 TX 帧（EOP error 和/或显式 FCS 校验失败）报 UVM_ERROR：agent、帧序号、长度、错误类型（含收到/计算的 CRC）与去向。
  protected function void report_tx_error(eth_seg_seq_item tx, int unsigned index, string outcome);
    string kind;
    if (!tx.inject_error && !(tx.fcs_present && !tx.fcs_ok)) return;
    tx_errors++;
    if (tx.inject_error) kind = "EOP error";
    if (tx.fcs_present && !tx.fcs_ok) begin
      byte unsigned body[];
      body = new[tx.frame_bytes.size() - 4];
      foreach (body[i]) body[i] = tx.frame_bytes[i];
      kind = {kind, (kind == "") ? "" : " + ",
              $sformatf("bad FCS (received 0x%08h, computed 0x%08h)", tx.fcs, eth_seg_codec::crc32(body))};
    end
    `uvm_error("ETH_LOOPBACK_TX_ERROR", $sformatf("%s: TX frame #%0d (%0d bytes) has %s; %s",
                                                   param_path, index, tx.frame_bytes.size(), kind, outcome))
  endfunction

  // TX monitor 在 EOP 调用，每帧先重读开关；关闭时不处理也不报错，开启后复位中、格式错误或无法编码的帧不回环。
  // 带错 TX 帧在决定去向后报告，去向取本帧当时的处理结果；入队帧之后的结局见 looped/flushed 计数。
  function void write_loopback_tx(eth_seg_seq_item tx);
    eth_seg_seq_item rx;
    int unsigned index;
    if (tx == null) return;
    index = tx_index++;
    if (!cfg.sample_loopback(param_path)) return;
    enabled_seen = 1;
    if (in_reset[ETH_SEG_TX] || in_reset[ETH_SEG_RX]) begin
      flushed_frames++;
      report_tx_error(tx, index, "flushed by reset");
      return;
    end
    // TX monitor 已对格式错误报 UVM_ERROR。
    if (tx.aborted) begin
      dropped_frames++;
      report_tx_error(tx, index, "dropped (TX format error)");
      return;
    end
    rx = to_rx(tx);
    if (rx.frame_bytes.size() < 9) begin
      dropped_frames++;
      `uvm_error("ETH_LOOPBACK_LEN", $sformatf("%s: %0d-byte RX frame cannot be looped (minimum 9)",
                                                param_path, rx.frame_bytes.size()))
      report_tx_error(tx, index, "dropped (too short for RX)");
      return;
    end
    if (frames.size() >= cfg.max_pending) begin
      dropped_frames++;
      `uvm_error("ETH_LOOPBACK_OVERFLOW", $sformatf("%s: loopback queue full (max_pending=%0d), TX frame dropped",
                                                     param_path, cfg.max_pending))
      report_tx_error(tx, index, "dropped (queue full)");
      return;
    end
    // initiator 随深拷贝进入 rx_driver.sent_ap，用于区分用户注入帧。
    rx.set_initiator(this);
    frames.push_back(rx);
    report_tx_error(tx, index, "queued for loopback unchanged");
  endfunction

  // hub 按方向发布复位：断言即清队；RX 复位时 rx_driver 丢弃全部副本，在途帧一并计入 flushed。
  function void write_loopback_reset(eth_seg_reset_notice_t notice);
    in_reset[notice.direction] = notice.asserted;
    if (!notice.asserted) return;
    flushed_frames += frames.size();
    frames.delete();
    if (notice.direction == ETH_SEG_RX) begin
      flushed_frames += in_flight;
      in_flight = 0;
    end
  endfunction

  // sent_ap 含用户注入帧，只统计本组件发起的回环帧。
  function void write_loopback_sent(eth_seg_seq_item item);
    if (item == null || item.get_initiator() != this) return;
    looped_frames++;
    if (in_flight != 0) in_flight--;
  endfunction

  task wait_frame();
    wait (frames.size() != 0);
  endtask

  // grant 后调用：队首帧复制进已启动的 item；队列已被复位清空时标 aborted，rx_driver 预取时直接丢弃。
  function void take_frame(eth_seg_seq_item item);
    if (frames.size() == 0) begin
      item.aborted = 1;
      return;
    end
    item.copy(frames.pop_front());
    in_flight++;
  endfunction

  // 常驻 sequence 不提 objection，关闭时只阻塞在 wait_frame，不参与仲裁。
  task run_phase(uvm_phase phase);
    eth_seg_loopback_seq#(RATE) seq;
    if (cfg == null || sequencer == null) begin
      `uvm_fatal("ETH_LOOPBACK_CFG", "loopback requires cfg and the agent sequencer")
      return;
    end
    enabled_seen = cfg.loopback;
    seq = eth_seg_loopback_seq#(RATE)::type_id::create("loopback_seq");
    seq.lb = this;
    seq.start(sequencer);
  endtask

  function void report_phase(uvm_phase phase);
    super.report_phase(phase);
    if (enabled_seen || looped_frames != 0 || flushed_frames != 0 || dropped_frames != 0)
      `uvm_info("ETH_LOOPBACK", $sformatf("%s: looped=%0d flushed=%0d dropped=%0d tx_errors=%0d pending=%0d",
                param_path, looped_frames, flushed_frames, dropped_frames, tx_errors, pending()), UVM_LOW)
  endfunction
endclass
