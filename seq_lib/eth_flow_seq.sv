// 线速发送 sequence（在 eth_flow_pkg 内编译）：用 flow_control rate_model 计算包间 gap_segments。
// 模型、计划时间与取整余量归本对象；每批锁定 sequencer，复位或时钟改频后应重新启动批次。
class eth_flow_seq extends eth_base_seq;
  `uvm_object_utils(eth_flow_seq)

  real rate_gbps = 0.0; // 0 表示使用绑定端口的 100/200/400G，显式速率必须大于零。
  real clk_freq_hz = 415039062.5; // 必须与实际用户时钟一致，不会在这里生成或修改时钟。
  int ifg_bytes = 12; // 正常 Ethernet 平均 IFG；允许更大间隔，不允许小于标准值。
  bit random_rate = 0;
  real rate_min_gbps = 0.0, rate_max_gbps = 0.0; // 随机模式必须显式给出合法范围。

  protected rate_model model;
  protected int port_rate, segments_per_cycle;
  protected bit preamble, include_fcs, initialized;
  protected real effective_rate, gap_remainder;
  protected realtime planned_time;
  longint unsigned wire_bytes_queued = 0;

  function new(string name = "eth_flow_seq");
    super.new(name);
  endfunction

  // 依次尝试三种 RATE 特化的 agent 配置，使 sequence/Tcl 类型保持非参数化；无标准 agent 或已启用旧负载节流时失败。
  protected function bit read_link();
    eth_seg_sequencer sqr_handle = require_sqr(1);
    eth_seg_agent#(100) a100;
    eth_seg_agent#(200) a200;
    eth_seg_agent#(400) a400;
    int old_load;
    bit old_random;

    if (sqr_handle == null) return 0;
    if ($cast(a100, sqr_handle.get_parent())) begin
      port_rate = 100;
      preamble = a100.cfg.preamble_passthrough;
      include_fcs = a100.cfg.include_fcs;
      old_load = a100.cfg.traffic_load_pct;
      old_random = a100.cfg.random_load;
    end else if ($cast(a200, sqr_handle.get_parent())) begin
      port_rate = 200;
      preamble = a200.cfg.preamble_passthrough;
      include_fcs = a200.cfg.include_fcs;
      old_load = a200.cfg.traffic_load_pct;
      old_random = a200.cfg.random_load;
    end else if ($cast(a400, sqr_handle.get_parent())) begin
      port_rate = 400;
      preamble = a400.cfg.preamble_passthrough;
      include_fcs = a400.cfg.include_fcs;
      old_load = a400.cfg.traffic_load_pct;
      old_random = a400.cfg.random_load;
    end else begin
      `uvm_fatal("ETH_FLOW_AGENT", "flow sequence requires an eth_seg_agent parent")
      return 0;
    end
    if (old_load != 100 || old_random) begin
      `uvm_fatal("ETH_FLOW_LOAD", "use traffic_load_pct=100 and random_load=0 with eth_flow_seq")
      return 0;
    end
    segments_per_cycle = port_rate / 25;
    return 1;
  endfunction

  // 每批重建预算；累计 ceil 取整使计划前缀不早于目标，批次边界最多多一个空段。
  // 时钟范围只拒绝无效/无穷值；能否达到目标速率按每包实际接口长度检查。
  protected function bit init_flow();
    initialized = 0;
    if (!read_link()) return 0;
    effective_rate = (rate_gbps == 0.0) ? real'(port_rate) : rate_gbps;
    if (!(effective_rate > 0.0 && effective_rate <= port_rate) ||
        !(clk_freq_hz > 0.0 && clk_freq_hz <= 1.0e12) || ifg_bytes < 12 || ifg_bytes > 1000000 ||
        (random_rate && !(rate_min_gbps > 0.0 && rate_max_gbps >= rate_min_gbps &&
                          rate_max_gbps <= effective_rate))) begin
      `uvm_fatal("ETH_FLOW_CFG", "invalid rate/clock/IFG or random rate range")
      return 0;
    end
    model = new();
    model.rate_mbps = effective_rate * 1000.0;
    model.reset();
    planned_time = 0.0;
    gap_remainder = 0.0;
    wire_bytes_queued = 0;
    initialized = 1;
    return 1;
  endfunction

  // 只改新事务：无 FCS 的短帧补到 60B 以免注入 runt，已带 FCS 的短帧不重算 CRC（负向 runt 测试用 eth_base_seq）。
  // 接口字节数与线速计费长度分开计算，前导/FCS 开关只影响前者。
  protected function bit shape_item(eth_seg_seq_item item, output int wire_bytes);
    int body_bytes, interface_bytes, data_segments, rounded_gap;
    real selected_rate, total_slots, gap_budget, rounded_real;
    realtime interval;

    wire_bytes = 0;
    if (item == null) return 0;
    if (item.fcs_present && (!include_fcs || item.frame_bytes.size() < 64)) begin
      `uvm_fatal("ETH_FLOW_FRAME", "explicit FCS requires include_fcs and a complete frame of at least 64 bytes")
      return 0;
    end
    if (!item.fcs_present && item.frame_bytes.size() < 60) begin
      int original_size = item.frame_bytes.size();
      item.frame_bytes = new[60](item.frame_bytes);
      for (int b = original_size; b < 60; b++) item.frame_bytes[b] = 0;
    end
    body_bytes = item.frame_bytes.size() - (item.fcs_present ? 4 : 0);
    wire_bytes = body_bytes + 4 + 8 + ifg_bytes;
    interface_bytes = item.frame_bytes.size() + (preamble ? 8 : 0) +
                      ((include_fcs && !item.fcs_present) ? 4 : 0);
    data_segments = (interface_bytes + 7) / 8;
    selected_rate = effective_rate;
    if (random_rate)
      selected_rate = rate_min_gbps + (rate_max_gbps-rate_min_gbps) *
                      ($urandom_range(0, 1000000) / 1000000.0);
    model.rate_mbps = selected_rate * 1000.0;
    interval = model.get_interval(wire_bytes, planned_time);
    total_slots = (interval / 1s) * clk_freq_hz * segments_per_cycle;
    if (!(total_slots >= data_segments)) begin
      `uvm_fatal("ETH_FLOW_CAPACITY", "user clock/interface cannot carry this frame at the requested wire rate")
      return 0;
    end
    gap_budget = total_slots - data_segments + gap_remainder;
    rounded_real = $ceil(gap_budget);
    if (!(rounded_real >= 0.0 && rounded_real <= 2147483647.0) || item.gap_segments < 0) begin
      `uvm_fatal("ETH_FLOW_GAP", "computed or explicit gap is outside the supported integer range")
      return 0;
    end
    rounded_gap = int'(rounded_real);
    gap_remainder = gap_budget - rounded_real;
    planned_time += interval;
    // 用户显式间隔是下限；不回收额外间隔为后续突发额度，反压同样只降低实际速率。
    if (rounded_gap > item.gap_segments) item.gap_segments = rounded_gap;
    return 1;
  endfunction

  // 只在实际发送路径推进模型（packet_to_item 不消耗预算）；start_item 前填好 gap_segments，driver 预取不会丢失。
  virtual task send_packet(input net_packet_pkg::packet net_pkt);
    eth_seg_seq_item item;
    int wire_bytes;

    last_send_ok = 0;
    if (!initialized) begin
      `uvm_fatal("ETH_FLOW_START", "start the flow sequence before calling send_packet")
      return;
    end
    item = packet_to_item(net_pkt);
    if (!shape_item(item, wire_bytes)) return;
    start_item(item);
    finish_item(item);
    wire_bytes_queued += wire_bytes;
    last_send_ok = 1;
  endtask

  // 一批一个锁，防止同端口其它 sequence 插包改变累计带宽；UVM kill 会自动移除锁。
  virtual task body();
    if (!init_flow()) return;
    lock();
    super.body();
    unlock();
    initialized = 0;
  endtask
endclass
