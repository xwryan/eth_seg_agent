// 可选 SHM 联仿绑定（依赖 shm_work 的 shm_uvm_pkg 与 shm_aip_pkg）：MAC active agent 置 shm=1 时按名字创建
// eth_seg_shm_link_<RATE>。TX monitor 在 EOP 发布的整帧编码进 SHM fabric，fabric 收到的帧经 agent 自身
// sequencer/rx_driver 回灌 RX，与 loopback 同一路径。每个仿真进程一个 endpoint、一个 binding "default"，
// 即只允许一个 shm=1 的 agent；端口、方向与就绪超时取自 SimFlow def_shm_cosim 生成的 +SHM_* plusarg。
`ifndef ETH_SEG_SHM_PKG_SV
`define ETH_SEG_SHM_PKG_SV
package eth_seg_shm_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import shm_uvm_pkg::*;
  import shm_aip_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  `uvm_analysis_imp_decl(_shm_link_tx)
  `uvm_analysis_imp_decl(_shm_link_sent)
  `uvm_analysis_imp_decl(_shm_link_reset)

  typedef class eth_seg_shm_link;

  // 已建 SHM 链路的 agent（与速率无关）：一个进程只有一个 endpoint 与 binding "default"。
  string shm_agent_path;

  // SHM 载荷就是线上帧：DA..payload 加 4 字节 FCS，不含前导。TX 已带 FCS（skip_crc）时原样保留（坏 FCS 照旧），
  // 否则补正确 CRC；EOP error 帧把 FCS 改成正确 CRC 取反，像 MAC 发错误帧那样让对端必报 FCS 错。
  // 接收端按自己的 include_fcs 保留或剥离 FCS，rx_fcs_error 只看载荷 FCS 是否正确；两端格式各自独立。
  class eth_seg_shm_codec extends shm_codec#(eth_seg_seq_item, eth_seg_seq_item);
    `uvm_object_utils(eth_seg_shm_codec)

    bit rx_include_fcs;              // 接收 agent 的 cfg.include_fcs
    int unsigned max_frame = 2032;   // 含 FCS 的最大载荷，等于 endpoint max_packet_size

    function new(string name = "eth_seg_shm_codec");
      super.new(name);
    endfunction

    virtual function bit encode(eth_seg_seq_item item, ref shm_frame frame);
      int n;
      bit [31:0] crc;
      byte unsigned body[];
      frame = null;
      if (item == null || item.aborted) return 0;
      n = item.frame_bytes.size() - (item.fcs_present ? 4 : 0);
      if (n < 9 || n + 4 > max_frame) return 0;
      body = new[n];
      foreach (body[i]) body[i] = item.frame_bytes[i];
      crc = eth_seg_codec::crc32(body);
      frame = shm_frame::type_id::create("eth_seg_shm_frame");
      if (frame == null) return 0;
      frame.payload = new[n + 4];
      foreach (body[i]) frame.payload[i] = body[i];
      for (int b = 0; b < 4; b++)
        frame.payload[n+b] = item.inject_error ? ~crc[b*8 +: 8] :
                             item.fcs_present ? item.frame_bytes[n+b] : crc[b*8 +: 8];
      return 1;
    endfunction

    // 一帧解成一个 RX 事务；剥离 FCS 后不足 9B（rx_driver 下限）或超过 max_frame 时失败，由 adapter fail closed。
    virtual function bit decode(shm_frame frame, ref eth_seg_seq_item items[$]);
      eth_seg_seq_item item;
      byte unsigned body[];
      bit [31:0] fcs;
      int n;
      items.delete();
      if (frame == null || frame.payload.size() > max_frame) return 0;
      n = frame.payload.size() - 4;
      if (n < 9) return 0;
      body = new[n];
      foreach (body[i]) body[i] = frame.payload[i];
      for (int b = 0; b < 4; b++) fcs[b*8 +: 8] = frame.payload[n+b];
      item = eth_seg_seq_item::type_id::create("eth_seg_shm_rx");
      if (item == null) return 0;
      if (rx_include_fcs) item.frame_bytes = frame.payload;
      else item.frame_bytes = body;
      item.fcs_present = rx_include_fcs;
      item.rx_fcs_error = (eth_seg_codec::crc32(body) != fcs);
      item.direction = ETH_SEG_RX;
      items.push_back(item);
      return 1;
    endfunction
  endclass

  // 常驻 owner sequence：agent sequencer 上唯一消费 SHM 解码队列的 sequence，一批即一帧，与用户 RX sequence 按帧交错。
  // RX 复位期间先等复位释放再驱动（两进程没有时间同步，早到的帧不算复位期间的帧）；grant 前后检查复位代次，
  // 复位清掉的帧标 aborted 交给 rx_driver 丢弃（同 loopback）。等帧期间不提 objection，像 loopback 一样空闲阻塞；
  // kill 时按 shm_work 模板撤销消费者占用。
  class eth_seg_shm_owner_seq #(int RATE = 100) extends uvm_sequence #(eth_seg_seq_item);
    `uvm_object_param_utils(eth_seg_shm_owner_seq#(RATE))
    typedef shm_item_source #(eth_seg_seq_item) source_t;
    typedef shm_item_batch #(eth_seg_seq_item) batch_t;

    eth_seg_shm_link#(RATE) link;
    source_t source;
    bit batch_held;
    bit consumer_active;
    process consumer_process;

    function new(string name = "eth_seg_shm_owner_seq");
      super.new(name);
    endfunction

    task body();
      shm_item_source_base base_source = shm_item_source_registry::find(m_sequencer);
      if (base_source == null || !$cast(source, base_source)) begin
        `uvm_fatal("ETH_SHM_SOURCE", "agent sequencer has no SHM source (RX binding not selected)")
        return;
      end
      forever begin
        batch_t batch;
        consumer_process = process::self();
        consumer_active = 1;
        source.get(batch);
        if (batch == null) begin
          consumer_active = 0;
          consumer_process = null;
          `uvm_fatal("ETH_SHM_SOURCE", "SHM source returned no batch")
          return;
        end
        batch_held = 1;
        link.received_frames++;
        foreach (batch.items[i]) begin
          eth_seg_seq_item item = batch.items[i];
          if (item == null) begin
            `uvm_fatal("ETH_SHM_SOURCE", "SHM source returned a null frame")
            return;
          end
          link.wait_rx_ready();
          if (!source.is_current(batch)) begin
            link.flushed_frames++;
            continue;
          end
          item.set_initiator(link);
          start_item(item);
          if (source.is_current(batch) && !link.rx_in_reset()) link.in_flight++;
          else begin
            item.aborted = 1;
            link.flushed_frames++;
          end
          finish_item(item);
        end
        source.release_batch();
        batch_held = 0;
        consumer_active = 0;
        consumer_process = null;
      end
    endtask

    virtual function void do_kill();
      process saved_owner = consumer_process;
      if (consumer_active && source != null && saved_owner != null) begin
        if (saved_owner == process::self()) begin
          if (batch_held) source.release_batch();
        end
        else begin
          if (saved_owner.status() != process::KILLED && saved_owner.status() != process::FINISHED)
            saved_owner.kill();
          if (saved_owner.status() == process::KILLED)
            source.cancel_consumer(saved_owner);
        end
      end
      batch_held = 0;
      consumer_active = 0;
      consumer_process = null;
      super.do_kill();
    endfunction
  endclass

  // agent 的子组件，build 时取父 agent 的 cfg/sequencer，connect 时自行接 TX monitor、rx_driver.sent_ap 与 hub reset_ap。
  // 拥有一个 shm_endpoint、一个 shm_agent_adapter（binding "default"）与 codec；队列全部有界，满即 fail closed。
  // 时间 0 等 fabric 就绪（墙钟，超时 +SHM_READY_TIMEOUT_MS，失败 fatal），仿真时间不前进，DUT 首帧必在就绪之后。
  class eth_seg_shm_link #(int RATE = 100) extends uvm_component;
    `uvm_component_param_utils(eth_seg_shm_link#(RATE))
    typedef shm_agent_adapter #(eth_seg_seq_item, eth_seg_seq_item) adapter_t;

    eth_seg_agent#(RATE) agent;
    eth_seg_config#(RATE) cfg;
    string param_path;  // aip 参数路径，即 agent 登记名
    shm_endpoint_config shm_cfg;
    shm_endpoint endpoint;
    adapter_t adapter;
    eth_seg_shm_codec codec;
    eth_seg_shm_owner_seq#(RATE) owner;
    uvm_analysis_imp_shm_link_tx#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) tx_export;
    uvm_analysis_imp_shm_link_sent#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) sent_export;
    uvm_analysis_imp_shm_link_reset#(eth_seg_reset_notice_t, eth_seg_shm_link#(RATE)) reset_export;
    uvm_analysis_port#(eth_seg_seq_item) adapter_ap;  // 过滤后的 TX 帧 → adapter.monitor_export

    // 按 agent 路径经 aip 读取（+<agent>.<名>）：队列深度（adapter/endpoint 各级与解码队列）、含 FCS 的最大帧长
    // （须 ≤ fabric slot_size-16）、fabric 满或对端暂停时发送重试的墙钟上限、接收空闲时每次轮询的宿主休眠。
    int unsigned shm_queue_depth = 256;
    int unsigned shm_max_frame = 2032;
    int unsigned shm_tx_timeout_ms = 1000;
    int unsigned shm_idle_sleep_us = 0;

    // sent：交给 adapter 的 TX 帧；received：从 fabric 取出的帧；driven：rx_driver 正沿完成的回灌帧；
    // flushed：复位清除；dropped：格式错误、过短或无目的端口；tx_errors：带 EOP error 或坏 FCS 的 TX 帧。
    int unsigned sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors;
    int unsigned in_flight;              // 已交 rx_driver、尚未完成
    protected int unsigned tx_index;     // TX monitor 帧序号，从 0 计
    protected bit in_reset[2] = '{1, 1}; // 收到 hub 首个复位通知前按复位处理
    protected bit ready, loopback_reported;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      tx_export = new("tx_export", this);
      sent_export = new("sent_export", this);
      reset_export = new("reset_export", this);
      adapter_ap = new("adapter_ap", this);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!$cast(agent, get_parent()) || agent == null || agent.cfg == null || agent.sequencer == null ||
          agent.rx_driver == null) begin
        `uvm_fatal("ETH_SHM_CFG", "eth_seg_shm_link must be created by a MAC active eth_seg_agent with shm=1")
        return;
      end
      cfg = agent.cfg;
      param_path = agent.get_full_name();
      if (shm_agent_path != "") begin
        `uvm_fatal("ETH_SHM_CFG", {"only one agent per simulation may set shm=1: ", shm_agent_path, " and ", param_path})
        return;
      end
      shm_agent_path = param_path;
      `aip_uint(param_path, int unsigned, shm_queue_depth, shm_queue_depth)
      `aip_uint(param_path, int unsigned, shm_max_frame, shm_max_frame)
      `aip_uint(param_path, int unsigned, shm_tx_timeout_ms, shm_tx_timeout_ms)
      `aip_uint(param_path, int unsigned, shm_idle_sleep_us, shm_idle_sleep_us)
      if (!shm_runtime::initialize()) return;
      if (!shm_runtime::is_enabled()) begin
        `uvm_fatal("ETH_SHM_CFG", {param_path, ".shm=1 requires +SHM_ENABLE=1 and the SHM transport plusargs ",
                                   "(SimFlow def_shm_cosim supplies them)"})
        return;
      end
      shm_cfg = shm_endpoint_config::type_id::create("shm_cfg");
      shm_cfg.shm_key = shm_runtime::key();
      shm_cfg.local_port = shm_runtime::local_port();
      shm_cfg.default_dst_port = (shm_runtime::destination_port() >= 0) ? shm_runtime::destination_port()
                                                                         : shm_runtime::local_port();
      shm_cfg.direction = shm_runtime::direction();
      shm_cfg.route_mode = SHM_ROUTE_FIXED;
      // 打开端口的重试上限与就绪超时同为 +SHM_READY_TIMEOUT_MS（SimFlow fabric.ready_timeout），按秒向上取整。
      shm_cfg.open_timeout_sec = (shm_runtime::ready_timeout_ms() + 999) / 1000;
      shm_cfg.queue_depth = shm_queue_depth;
      shm_cfg.max_packet_size = shm_max_frame;
      shm_cfg.tx_retry_delay_us = 1000;
      shm_cfg.tx_retry_limit = shm_tx_timeout_ms;
      shm_cfg.rx_idle_sleep_us = shm_idle_sleep_us;
      if (!shm_cfg.validate()) begin
        `uvm_fatal("ETH_SHM_CFG", $sformatf({"%s: invalid SHM settings shm_queue_depth=%0d (>0) shm_max_frame=%0d (1..16368) ",
                                             "shm_tx_timeout_ms=%0d (>0) shm_idle_sleep_us=%0d (<1000000)"},
                                            param_path, shm_queue_depth, shm_max_frame, shm_tx_timeout_ms, shm_idle_sleep_us))
        return;
      end
      endpoint = shm_endpoint::type_id::create("endpoint", this);
      endpoint.cfg = shm_cfg;
      adapter = adapter_t::type_id::create("adapter", this);
      adapter.cfg = shm_cfg;
      adapter.binding_name = "default";
      adapter.source_depth = shm_queue_depth;
      codec = eth_seg_shm_codec::type_id::create("codec");
      codec.rx_include_fcs = cfg.include_fcs;
      codec.max_frame = shm_max_frame;
      adapter.codec = codec;
    endfunction

    // RX 能力时把 agent 自己的 sequencer 与 adapter 解码队列登记为 binding "default"，endpoint 在 end_of_elaboration 选中。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (endpoint == null) return;
      agent.tx_monitor.item_collected_port.connect(tx_export);
      agent.rx_driver.sent_ap.connect(sent_export);
      agent.monitor_hub.reset_ap.connect(reset_export);
      adapter_ap.connect(adapter.monitor_export);
      if (shm_cfg.direction != SHM_RX_ONLY) adapter.shm_tx_ap.connect(endpoint.tx_export);
      if (shm_cfg.direction != SHM_TX_ONLY) begin
        endpoint.rx_ap.connect(adapter.shm_rx_export);
        void'(shm_binding_registry::register_binding("default", adapter, agent.sequencer, adapter.get_item_source(),
                                                     shm_cfg.direction != SHM_RX_ONLY, 1));
      end
      else
        void'(shm_binding_registry::register_binding("default", adapter, null, null, 1, 0));
    endfunction

    // SHM 收发活动推进 AIP 活动计数，供 end_test 空闲判断与 Tcl ACK 等待使用。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (endpoint != null) install_shm_aip_hooks();
    endfunction

    task run_phase(uvm_phase phase);
      bit ok;
      if (endpoint == null) return;
      shm_runtime::ensure_ready(ok);
      if (!ok) return;
      ready = 1;
      if (shm_cfg.direction == SHM_TX_ONLY) return;
      owner = eth_seg_shm_owner_seq#(RATE)::type_id::create("shm_owner_seq");
      owner.link = this;
      owner.start(agent.sequencer);
    endtask

    function bit rx_in_reset();
      return in_reset[ETH_SEG_RX];
    endfunction

    // owner 每帧驱动前调用：RX 复位期间阻塞到释放（与 loopback 的 wait_frame 一样是无 objection 的空闲等待）。
    task wait_rx_ready();
      wait (!in_reset[ETH_SEG_RX]);
    endtask

    // 解码队列与已交 rx_driver 未完成的帧；TX 侧以 endpoint 计数与 tx_pending_count/tx_is_busy 为准。
    function int unsigned pending();
      shm_item_source_base source = (adapter == null) ? null : adapter.get_item_source();
      return ((source == null) ? 0 : source.pending_count()) + ((owner != null && owner.batch_held) ? 1 : 0) + in_flight;
    endfunction

    function bit is_idle();
      return pending() == 0 && (adapter == null || adapter.tx_pending_count() == 0) &&
             (endpoint == null || (endpoint.tx_pending_count() == 0 && !endpoint.tx_is_busy()));
    endfunction

    // 带错 TX 帧（EOP error 和/或显式 FCS 校验失败）报 ETH_SHM_TX_ERROR（UVM_ERROR，可降级）：帧序号、长度、错误类型与去向。
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
      `uvm_error("ETH_SHM_TX_ERROR", $sformatf("%s: TX frame #%0d (%0d bytes) has %s; %s",
                                                param_path, index, tx.frame_bytes.size(), kind, outcome))
    endfunction

    // TX monitor 在 EOP 调用：TX 复位中、格式错误、过短或本节点无目的端口的帧不发送并计数；超长帧 fail closed；
    // 其余帧交 adapter（满即 fatal）。loopback 每帧重读，运行中打开即报 ETH_SHM_LOOPBACK。
    function void write_shm_link_tx(eth_seg_seq_item tx);
      int unsigned index;
      int body_len;
      if (tx == null || endpoint == null) return;
      index = tx_index++;
      if (cfg.sample_loopback(param_path) && !loopback_reported) begin
        loopback_reported = 1;
        `uvm_error("ETH_SHM_LOOPBACK", {param_path, ": loopback and shm are mutually exclusive; frames still go to SHM"})
      end
      if (!ready) begin
        shm_runtime::fail($sformatf("%s: TX frame #%0d before SHM readiness", param_path, index));
        return;
      end
      if (in_reset[ETH_SEG_TX]) begin
        flushed_frames++;
        report_tx_error(tx, index, "flushed by reset");
        return;
      end
      if (tx.aborted) begin
        dropped_frames++;
        report_tx_error(tx, index, "dropped (TX format error)");
        return;
      end
      if (shm_cfg.direction == SHM_RX_ONLY) begin
        dropped_frames++;
        `uvm_error("ETH_SHM_NO_ROUTE", $sformatf("%s: TX frame #%0d dropped: this SHM node has no destination (RX_ONLY)",
                                                  param_path, index))
        return;
      end
      body_len = tx.frame_bytes.size() - (tx.fcs_present ? 4 : 0);
      if (body_len < 9) begin
        dropped_frames++;
        `uvm_error("ETH_SHM_LEN", $sformatf("%s: TX frame #%0d has %0d bytes before FCS; SHM needs at least 9",
                                             param_path, index, body_len))
        report_tx_error(tx, index, "dropped (too short)");
        return;
      end
      if (body_len + 4 > shm_max_frame) begin
        shm_runtime::fail($sformatf("%s: TX frame #%0d is %0d bytes with FCS, above shm_max_frame=%0d; raise +%s.shm_max_frame and the fabric slot_size",
                                    param_path, index, body_len + 4, shm_max_frame, param_path));
        return;
      end
      report_tx_error(tx, index, tx.inject_error ? "sent to SHM with the FCS inverted" : "sent to SHM with its FCS unchanged");
      adapter_ap.write(tx);
      sent_frames++;
    endfunction

    // 按 shm_work 模板在复位断言沿清队，按方向拆开：TX 断言清 adapter 的 TX 队列（endpoint 已收下的帧视为已上线路），
    // RX 断言清解码队列并让 epoch 加一（owner 逐帧判旧），rx_driver 丢弃的在途帧一并计入 flushed。
    // 仿真开始时按复位处理，首个通知不算断言沿，避免清掉对端早于本端复位释放到达的帧。
    function void write_shm_link_reset(eth_seg_reset_notice_t notice);
      shm_item_source_base source;
      bit was_in_reset = in_reset[notice.direction];
      in_reset[notice.direction] = notice.asserted;
      if (!notice.asserted || was_in_reset || adapter == null) return;
      if (notice.direction == ETH_SEG_TX) begin
        flushed_frames += adapter.tx_pending_count();
        if (adapter.tx_fifo != null) adapter.tx_fifo.flush();
        return;
      end
      source = adapter.get_item_source();
      if (source != null) begin
        flushed_frames += source.pending_count();
        source.flush();
      end
      flushed_frames += in_flight;
      in_flight = 0;
    endfunction

    // sent_ap 含用户注入帧，只统计本链路回灌的帧。
    function void write_shm_link_sent(eth_seg_seq_item item);
      if (item == null || item.get_initiator() != this) return;
      driven_frames++;
      if (in_flight != 0) in_flight--;
    endfunction

    function void report_phase(uvm_phase phase);
      super.report_phase(phase);
      if (endpoint != null)
        `uvm_info("ETH_SHM", $sformatf("%s: sent=%0d received=%0d driven=%0d flushed=%0d dropped=%0d tx_errors=%0d pending=%0d",
                  param_path, sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors,
                  pending()), UVM_LOW)
    endfunction
  endclass

  // agent 只认名字（基础包不依赖本包），三档速率各登记一个。
  typedef uvm_component_registry #(eth_seg_shm_link#(100), "eth_seg_shm_link_100") eth_seg_shm_link_100_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(200), "eth_seg_shm_link_200") eth_seg_shm_link_200_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(400), "eth_seg_shm_link_400") eth_seg_shm_link_400_registry;
endpackage
`endif
