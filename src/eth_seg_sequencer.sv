// 非参数化 sequencer，只处理字节事务；静态 sqr 表按完整 agent 名区分实例，100/200/400G 共用一张表。
// driver 的 item_done 只表示副本入队，物理完成以 sent_ap 为准。
class eth_seg_sequencer extends uvm_sequencer #(eth_seg_seq_item);
  `uvm_component_utils(eth_seg_sequencer)

  static eth_seg_sequencer sqr[string];
  eth_seg_monitor_hub monitor_hub;
  bit can_send = 0;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  // 在 agent.connect_phase 连接 driver 后登记；重复名字或空句柄立即失败。
  static function void register_sqr(string agent_name, eth_seg_sequencer handle);
    if (agent_name == "" || handle == null) begin
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", "agent name and sequencer must be non-null");
      return;
    end
    if (sqr.exists(agent_name)) begin
      uvm_pkg::uvm_report_fatal("ETH_SQR_REGISTER", {"duplicate sequencer: ", agent_name});
      return;
    end
    sqr[agent_name] = handle;
  endfunction

  // connect 前或名字错误返回 null；passive 返回仅供采样的 sqr，发送前需检查 can_send。
  static function eth_seg_sequencer get_sqr(string agent_name);
    if (!sqr.exists(agent_name)) return null;
    return sqr[agent_name];
  endfunction

  // 只删除仍指向本对象的表项。
  static function void unregister_sqr(string agent_name, eth_seg_sequencer handle);
    if (sqr.exists(agent_name))
      if (sqr[agent_name] == handle) sqr.delete(agent_name);
  endfunction

  // 手工构建的 sequencer 也必须显式提供 hub。
  protected function bit require_hub();
    if (monitor_hub == null) begin
      `uvm_fatal("ETH_SAMPLE_HUB", "sequencer has no monitor hub")
      return 0;
    end
    return 1;
  endfunction

  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    if (require_hub()) monitor_hub.subscribe(dir, portid, depth);
  endfunction

  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    tr = null;
    if (require_hub()) monitor_hub.mon_xaction(tr, dir, portid, timeout);
  endtask

  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    if (require_hub()) monitor_hub.unsubscribe(dir, portid);
  endfunction
endclass
