// 整包采样 hub：双向 monitor 在 EOP 发布的整包是唯一数据源，每个 (direction, portid) 订阅持有独立副本队列。
// 不驱动引脚、不解析 segment；复位按方向清空队列，订阅和等待者保留。
`uvm_analysis_imp_decl(_sample_tx)
`uvm_analysis_imp_decl(_sample_rx)
`uvm_analysis_imp_decl(_sample_reset_tx)
`uvm_analysis_imp_decl(_sample_reset_rx)

// 槽独立成对象：取消后旧等待者仍引用旧槽，不会误取同编号新订阅的数据。
class eth_seg_subscription;
  eth_seg_seq_item frames[$];
  int unsigned depth;
  bit active = 1;
  process reader;

  function new(int unsigned depth);
    this.depth = depth;
  endfunction
endclass

class eth_seg_monitor_hub extends uvm_component;
  `uvm_component_utils(eth_seg_monitor_hub)

  uvm_analysis_imp_sample_tx#(eth_seg_seq_item, eth_seg_monitor_hub) sample_tx;
  uvm_analysis_imp_sample_rx#(eth_seg_seq_item, eth_seg_monitor_hub) sample_rx;
  uvm_analysis_imp_sample_reset_tx#(bit, eth_seg_monitor_hub) reset_tx;
  uvm_analysis_imp_sample_reset_rx#(bit, eth_seg_monitor_hub) reset_rx;
  uvm_analysis_port#(eth_seg_reset_notice_t) reset_ap;

  protected eth_seg_subscription slots[2][int unsigned];
  protected bit reset_known[2], in_reset[2];
  protected int unsigned reset_epoch[2];

  function new(string name = "monitor_hub", uvm_component parent = null);
    super.new(name, parent);
    sample_tx = new("sample_tx", this);
    sample_rx = new("sample_rx", this);
    reset_tx = new("reset_tx", this);
    reset_rx = new("reset_rx", this);
    reset_ap = new("reset_ap", this);
  endfunction

  // 非法方向会越界索引固定数组；fatal 被 catcher 吞掉时仍返回 0。
  protected function bit valid_dir(eth_seg_dir_e dir);
    if (!(dir inside {ETH_SEG_TX, ETH_SEG_RX})) begin
      `uvm_fatal("ETH_SAMPLE_CFG", "sampling direction must be TX or RX")
      return 0;
    end
    return 1;
  endfunction

  // 未订阅时报错，不隐式订阅。
  protected function eth_seg_subscription get_slot(eth_seg_dir_e dir, int unsigned portid);
    if (!valid_dir(dir)) return null;
    if (!slots[dir].exists(portid)) begin
      `uvm_fatal("ETH_SAMPLE_SUB", $sformatf("unsubscribed %s consumer %0d", dir.name(), portid))
      return null;
    end
    return slots[dir][portid];
  endfunction

  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    if (!valid_dir(dir)) return;
    if (depth == 0 || slots[dir].exists(portid)) begin
      `uvm_fatal("ETH_SAMPLE_CFG", "subscription requires positive depth and unused portid")
      return;
    end
    slots[dir][portid] = new(depth);
  endfunction

  // 清空队列并唤醒旧等待者；重复取消无副作用，重订阅会创建新槽。
  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_subscription slot;
    if (!valid_dir(dir)) return;
    if (!slots[dir].exists(portid)) return;
    slot = slots[dir][portid];
    slot.active = 0;
    slot.frames.delete();
    slots[dir].delete(portid);
  endfunction

  function int unsigned pending(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_subscription slot = get_slot(dir, portid);
    return slot == null ? 0 : slot.frames.size();
  endfunction

  // 只表示缓存为空；结束测试还需核对数量及 driver/monitor/RM 在途状态。
  function bit is_idle();
    foreach (slots[d,p]) if (slots[d][p].frames.size() != 0) return 0;
    return 1;
  endfunction

  // 有包立即返回，否则阻塞到入包、取消或非零 timeout 到期（复位不重启计时）；取消/超时返回 null，超时报 ERROR。
  // 同一槽同时只允许一个活跃读者；读者进程被 kill 后可由新读者接管。
  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    eth_seg_subscription slot;
    time started, remaining;
    tr = null;
    slot = get_slot(dir, portid);
    if (slot == null) return;
    if (slot.reader != null) begin
      if (!(slot.reader.status() inside {process::FINISHED, process::KILLED})) begin
        `uvm_fatal("ETH_SAMPLE_READER", "only one live reader is allowed per subscription")
        return;
      end
    end
    slot.reader = process::self();
    started = $time;
    forever begin
      if (!slot.active) begin
        slot.reader = null;
        return;
      end
      if (slot.frames.size() != 0) begin
        tr = slot.frames.pop_front();
        slot.reader = null;
        return;
      end
      if (timeout != 0 && $time-started >= timeout) begin
        slot.reader = null;
        `uvm_error("ETH_SAMPLE_TIMEOUT", $sformatf("no complete %s frame for consumer %0d within %0t", dir.name(), portid, timeout))
        return;
      end
      remaining = timeout == 0 ? 0 : timeout-($time-started);
      // 独立子进程限制 disable fork 的作用域，不能杀死调用者的其它线程。
      // 唤醒后重新检查：同一时刻复位可能已删除刚入队的包，必须继续等原截止时间。
      fork
        begin
          fork
            wait (!slot.active || slot.frames.size() != 0);
            begin
              if (timeout != 0) #(remaining);
              else wait (1'b0);
            end
          join_any
          disable fork;
        end
      join
    end
  endtask

  // 先检查所有订阅的容量再复制，fatal 被捕获时也不会部分广播；没有订阅者时不保留历史。
  protected function void publish(eth_seg_dir_e dir, eth_seg_seq_item item);
    if (item == null) begin
      `uvm_fatal("ETH_SAMPLE_NULL", "monitor published a null frame")
      return;
    end
    if (reset_known[dir] && in_reset[dir]) return;
    foreach (slots[d,p]) if (d == int'(dir)) begin
      if (slots[dir][p].frames.size() >= slots[dir][p].depth) begin
        `uvm_fatal("ETH_SAMPLE_OVERFLOW", $sformatf("%s consumer %0d exceeded %0d frames", dir.name(), p, slots[dir][p].depth))
        return;
      end
    end
    foreach (slots[d,p]) if (d == int'(dir)) begin
      eth_seg_seq_item copy = eth_seg_seq_item::type_id::create("sample_copy");
      copy.copy(item);
      slots[dir][p].frames.push_back(copy);
    end
  endfunction

  function void write_sample_tx(eth_seg_seq_item item);
    publish(ETH_SEG_TX, item);
  endfunction

  function void write_sample_rx(eth_seg_seq_item item);
    publish(ETH_SEG_RX, item);
  endfunction

  // 首次同步复位状态，之后只发布变化：先清本方向缓存再通知用户；已取出的包和预测线程由用户自行清理。
  protected function void observe_reset(eth_seg_dir_e dir, bit asserted);
    eth_seg_reset_notice_t notice;
    if (reset_known[dir] && in_reset[dir] == asserted) return;
    reset_known[dir] = 1;
    in_reset[dir] = asserted;
    if (asserted) begin
      reset_epoch[dir]++;
      foreach (slots[d,p]) if (d == int'(dir)) slots[d][p].frames.delete();
    end
    notice.direction = dir;
    notice.asserted = asserted;
    notice.epoch = reset_epoch[dir];
    reset_ap.write(notice);
  endfunction

  function void write_sample_reset_tx(bit asserted);
    observe_reset(ETH_SEG_TX, asserted);
  endfunction

  // 只影响 RX 订阅；整链路清理策略由订阅 reset_ap 的 RM/test 决定。
  function void write_sample_reset_rx(bit asserted);
    observe_reset(ETH_SEG_RX, asserted);
  endfunction
endclass
