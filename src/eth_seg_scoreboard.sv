// 双向异步 expected/actual FIFO scoreboard：期望来自 driver EOP 通知或用户 RM（同一队列只选一个来源），输入均深拷贝。
// 按到达顺序匹配，不依赖时间戳、sequence id 或 UVM 调度顺序；check_phase 对残留报错，使丢包和重复包可见。
`uvm_analysis_imp_decl(_expect_tx)
`uvm_analysis_imp_decl(_expect_rx)
`uvm_analysis_imp_decl(_actual_tx)
`uvm_analysis_imp_decl(_actual_rx)
class eth_seg_scoreboard extends uvm_component;
  `uvm_component_utils(eth_seg_scoreboard)

  uvm_analysis_imp_expect_tx#(eth_seg_seq_item, eth_seg_scoreboard) expect_tx;
  uvm_analysis_imp_expect_rx#(eth_seg_seq_item, eth_seg_scoreboard) expect_rx;
  uvm_analysis_imp_actual_tx#(eth_seg_seq_item, eth_seg_scoreboard) actual_tx;
  uvm_analysis_imp_actual_rx#(eth_seg_seq_item, eth_seg_scoreboard) actual_rx;
  eth_seg_seq_item expect_tx_fifo[$], expect_rx_fifo[$];
  eth_seg_seq_item actual_tx_fifo[$], actual_rx_fifo[$];
  int unsigned matched_tx, matched_rx, mismatch_tx, mismatch_rx;

  function new(string name = "eth_seg_scoreboard", uvm_component parent = null);
    super.new(name, parent);
    expect_tx = new("expect_tx", this);
    expect_rx = new("expect_rx", this);
    actual_tx = new("actual_tx", this);
    actual_rx = new("actual_rx", this);
  endfunction

  function bit same_item(input eth_seg_seq_item exp, input eth_seg_seq_item act,
                         input bit is_rx, output string why);
    why = "";
    if (exp.frame_bytes.size() != act.frame_bytes.size()) begin
      why = $sformatf("frame length expected %0d actual %0d", exp.frame_bytes.size(), act.frame_bytes.size());
      return 0;
    end
    foreach (exp.frame_bytes[i]) if (exp.frame_bytes[i] != act.frame_bytes[i]) begin
      why = $sformatf("frame byte[%0d] expected %02x actual %02x", i, exp.frame_bytes[i], act.frame_bytes[i]);
      return 0;
    end
    if (exp.fcs_present != act.fcs_present) begin why = "fcs_present mismatch"; return 0; end
    if (is_rx) begin
      if (exp.rx_fcs_error != act.rx_fcs_error) begin why = "rx_fcs_error mismatch"; return 0; end
      if (exp.rx_error != act.rx_error) begin why = "rx_error mismatch"; return 0; end
      if (exp.rx_status != act.rx_status) begin why = "rx_status mismatch"; return 0; end
    end
    else if (exp.inject_error != act.inject_error) begin
      why = "EOP inject_error mismatch";
      return 0;
    end
    return 1;
  endfunction

  function void try_match(input bit is_rx);
    eth_seg_seq_item exp, act;
    string why;
    if (is_rx) begin
      if (expect_rx_fifo.size() == 0 || actual_rx_fifo.size() == 0) return;
      exp = expect_rx_fifo.pop_front(); act = actual_rx_fifo.pop_front();
      if (same_item(exp, act, 1, why)) matched_rx++;
      else begin mismatch_rx++; `uvm_error("ETH_SEG_SB_RX", $sformatf("ETH_SEG_RX_MISMATCH: %s", why)) end
    end
    else begin
      if (expect_tx_fifo.size() == 0 || actual_tx_fifo.size() == 0) return;
      exp = expect_tx_fifo.pop_front(); act = actual_tx_fifo.pop_front();
      if (same_item(exp, act, 0, why)) matched_tx++;
      else begin mismatch_tx++; `uvm_error("ETH_SEG_SB_TX", $sformatf("ETH_SEG_TX_MISMATCH: %s", why)) end
    end
  endfunction

  function void write_expect_tx(eth_seg_seq_item item);
    eth_seg_seq_item c;
    if (item == null) begin
      `uvm_error("ETH_SEG_SB_NULL", "scoreboard input must be a complete non-null transaction")
      return;
    end
    c = new("sb_exp_tx");
    c.copy(item);
    expect_tx_fifo.push_back(c);
    try_match(0);
  endfunction
  function void write_expect_rx(eth_seg_seq_item item);
    eth_seg_seq_item c;
    if (item == null) begin
      `uvm_error("ETH_SEG_SB_NULL", "scoreboard input must be a complete non-null transaction")
      return;
    end
    c = new("sb_exp_rx");
    c.copy(item);
    expect_rx_fifo.push_back(c);
    try_match(1);
  endfunction
  function void write_actual_tx(eth_seg_seq_item item);
    eth_seg_seq_item c;
    if (item == null) begin
      `uvm_error("ETH_SEG_SB_NULL", "scoreboard input must be a complete non-null transaction")
      return;
    end
    c = new("sb_act_tx");
    c.copy(item);
    actual_tx_fifo.push_back(c);
    try_match(0);
  endfunction
  function void write_actual_rx(eth_seg_seq_item item);
    eth_seg_seq_item c;
    if (item == null) begin
      `uvm_error("ETH_SEG_SB_NULL", "scoreboard input must be a complete non-null transaction")
      return;
    end
    c = new("sb_act_rx");
    c.copy(item);
    actual_rx_fifo.push_back(c);
    try_match(1);
  endfunction

  // RM 直接提交 TX 出口期望；实际包可以先到，返回不代表已匹配。
  function void write_before(eth_seg_seq_item item);
    write_expect_tx(item);
  endfunction

  // 采样线程直接提交 TX 出口实际包。
  function void write_after(eth_seg_seq_item item);
    write_actual_tx(item);
  endfunction

  // 供复位时丢弃在途事务；只清指定方向，不清累计匹配/错误计数。
  function void flush_direction(eth_seg_dir_e dir);
    case (dir)
      ETH_SEG_TX: begin expect_tx_fifo.delete(); actual_tx_fifo.delete(); end
      ETH_SEG_RX: begin expect_rx_fifo.delete(); actual_rx_fifo.delete(); end
      default: `uvm_error("ETH_SEG_SB_DIR", "flush direction must be TX or RX")
    endcase
  endfunction

  function bit is_idle();
    return expect_tx_fifo.size() == 0 && expect_rx_fifo.size() == 0 &&
           actual_tx_fifo.size() == 0 && actual_rx_fifo.size() == 0;
  endfunction

  function void check_phase(uvm_phase phase);
    super.check_phase(phase);
    if (expect_tx_fifo.size() || actual_tx_fifo.size())
      `uvm_error("ETH_SEG_SB_TX_REMAINDER", $sformatf("ETH_SEG_TX_REMAINDER: expected=%0d actual=%0d", expect_tx_fifo.size(), actual_tx_fifo.size()))
    if (expect_rx_fifo.size() || actual_rx_fifo.size())
      `uvm_error("ETH_SEG_SB_RX_REMAINDER", $sformatf("ETH_SEG_RX_REMAINDER: expected=%0d actual=%0d", expect_rx_fifo.size(), actual_rx_fifo.size()))
  endfunction
endclass
