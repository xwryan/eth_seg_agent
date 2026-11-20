// 可选 SHM 联仿绑定（依赖 shm_work 的 shm_uvm_pkg 与 shm_aip_pkg）：MAC active agent 置 shm=1 时按名字创建
// eth_seg_shm_link_<RATE>。TX monitor 在 EOP 发布的整帧编码进 SHM fabric，fabric 收到的帧经 agent 自身
// sequencer/rx_driver 回灌 RX，与 loopback 同一路径。每个仿真进程一个 endpoint、一个 binding "default"，
// 即只允许一个 shm=1 的 agent；端口、方向与就绪超时取自 SimFlow def_shm_cosim 生成的 +SHM_* plusarg。
// 另有带内控制通道（两个仿真之间的握手）：Tcl eth_shm_signal/eth_shm_wait，帧格式与语义见 eth_seg_shm_link_base。
`ifndef ETH_SEG_SHM_PKG_SV
`define ETH_SEG_SHM_PKG_SV
package eth_seg_shm_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import shm_sv_port_api::*;
  import shm_uvm_pkg::*;
  import shm_aip_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  `uvm_analysis_imp_decl(_shm_link_tx)
  `uvm_analysis_imp_decl(_shm_link_sent)
  `uvm_analysis_imp_decl(_shm_link_reset)
  `uvm_analysis_imp_decl(_shm_link_rx)

  typedef class eth_seg_shm_link;

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

  // 进程内唯一 SHM 链路与速率无关的部分：endpoint、adapter、codec、参数，以及两个仿真之间的带内控制通道。
  // 控制帧是普通以太网帧：DA 全 1、SA 02:00:00:00:00:00、EtherType 0x88B5（IEEE 本地实验类型），载荷依次为魔数
  // "ETHSHMC1"、名字长度（1B）、名字、数据长度（2B，大端）与数据，不足 60B 补零，FCS 由 codec 补正确 CRC。它与 DUT 帧
  // 走同一条 TX 队列（保序，先发的 DUT 帧先到），对端链路在 endpoint 与 adapter 之间截下（EtherType 与魔数都匹配才算），
  // 不交给 adapter、不进 DUT，按名字排队缓存，等本端 wait 取走；EtherType 相同而魔数不同的帧照常是 DUT 帧。
  // 控制帧计入 endpoint 的收发计数（SHM_ENDPOINT_COUNTERS、shm_transport 检查器），不计入 sent/received/driven。
  virtual class eth_seg_shm_link_base extends uvm_component;
    typedef shm_agent_adapter #(eth_seg_seq_item, eth_seg_seq_item) adapter_t;
    localparam bit [15:0] CTRL_TYPE = 16'h88b5;
    localparam bit [63:0] CTRL_MAGIC = 64'h4554_4853_484d_4331;  // "ETHSHMC1"
    localparam int unsigned CTRL_HEAD = 22;                      // DA/SA/EtherType 14B + 魔数 8B
    localparam int unsigned CTRL_NAME_MAX = 64;
    // 数据上限给 Tcl 结果 "OK: eth_shm_wait: <数据>" 留出余量（AIP 命令与结果各限 1024B）。
    localparam int unsigned CTRL_DATA_MAX = 1000;

    // 本进程唯一的 shm=1 链路（build 时登记），也是 eth_shm_signal/eth_shm_wait 的目标。
    static eth_seg_shm_link_base active;

    string param_path;  // aip 参数路径，即 agent 登记名
    shm_endpoint_config shm_cfg;
    shm_endpoint endpoint;
    adapter_t adapter;
    eth_seg_shm_codec codec;
    uvm_analysis_port#(eth_seg_seq_item) adapter_ap;                             // TX 帧（DUT 帧与控制帧）→ adapter
    uvm_analysis_imp_shm_link_rx#(shm_frame, eth_seg_shm_link_base) rx_export;  // endpoint.rx_ap → 截下控制帧
    uvm_analysis_port#(shm_frame) adapter_rx_ap;                                // 其余帧 → adapter.shm_rx_export

    // 按 agent 路径经 aip 读取（+<agent>.<名>）：队列深度（adapter/endpoint 各级、解码队列与控制信号缓存）、含 FCS 的
    // 最大帧长（须 ≤ fabric slot_size-16）、fabric 满或对端暂停时发送重试的墙钟上限、接收空闲时每次轮询的宿主休眠；
    // 控制通道等待时每次轮询推进的仿真时间（等待期间 endpoint 也按它轮询）与宿主休眠、eth_shm_wait 缺省的墙钟上限。
    int unsigned shm_queue_depth = 256;
    int unsigned shm_max_frame = 2032;
    int unsigned shm_tx_timeout_ms = 1000;
    int unsigned shm_idle_sleep_us = 0;
    int unsigned shm_wait_poll_ns = 1;
    int unsigned shm_wait_sleep_us = 1000;
    int unsigned shm_wait_timeout_ms = 600000;

    // ctrl_sent：已交给 switch 的控制帧；ctrl_received：收下并缓存的；ctrl_dropped：FCS 或格式错误而丢弃的。
    int unsigned ctrl_sent, ctrl_received, ctrl_dropped;
    protected bit ready;
    protected string ctrl_box[string][$];  // 名字 → 按到达顺序缓存、尚未被 wait 取走的数据
    protected int unsigned ctrl_buffered;
    protected int unsigned fast_poll_users;
    protected time saved_poll_interval;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      adapter_ap = new("adapter_ap", this);
      rx_export = new("rx_export", this);
      adapter_rx_ap = new("adapter_rx_ap", this);
    endfunction

    // 名字 1..64 个字符，只含字母、数字与 _ . : -；数据至多 1000 个可打印 ASCII 字符（0x20..0x7e），可以为空。
    static function bit check_signal(string name, string data, output string why);
      why = "";
      if (name.len() == 0 || name.len() > CTRL_NAME_MAX) begin
        why = $sformatf("name='%s': needs 1..%0d characters", name, CTRL_NAME_MAX);
        return 0;
      end
      foreach (name[i]) begin
        byte c = name[i];
        if (!((c >= 8'h30 && c <= 8'h39) || (c >= 8'h41 && c <= 8'h5a) || (c >= 8'h61 && c <= 8'h7a) ||
              c inside {8'h5f, 8'h2e, 8'h3a, 8'h2d})) begin
          why = {"name=", name, ": only letters, digits and _ . : - are allowed"};
          return 0;
        end
      end
      if (data.len() > CTRL_DATA_MAX) begin
        why = $sformatf("data has %0d characters, at most %0d", data.len(), CTRL_DATA_MAX);
        return 0;
      end
      foreach (data[i])
        if (data[i] < 8'h20 || data[i] > 8'h7e) begin
          why = $sformatf("data character %0d is 0x%02h; only printable ASCII is allowed", i, data[i]);
          return 0;
        end
      return 1;
    endfunction

    // 能否收发控制帧：链路已建、fabric 已就绪、没有锁存的传输错误，且本节点有对应方向。
    protected function bit can_use(bit tx, output string why);
      why = "";
      if (endpoint == null || adapter == null)
        why = {param_path, ": the SHM link has no endpoint (needs +SHM_ENABLE=1 from SimFlow def_shm_cosim)"};
      else if (link_failed(why))
        return 0;
      else if (!ready)
        why = {param_path, ": the SHM fabric is not ready yet"};
      else if (tx && shm_cfg.direction == SHM_RX_ONLY)
        why = {param_path, ": this SHM node has no destination (RX_ONLY)"};
      else if (!tx && shm_cfg.direction == SHM_TX_ONLY)
        why = {param_path, ": this SHM node does not receive (TX_ONLY)"};
      return why == "";
    endfunction

    protected function bit link_failed(output string why);
      why = "";
      if (shm_runtime::has_failed() || (endpoint != null && endpoint.has_irreversible_error()))
        why = {"SHM transport failed: ", shm_runtime::last_error()};
      return why != "";
    endfunction

    // 等待中的一次轮询：宿主休眠 shm_wait_sleep_us，仿真时间只推进 shm_wait_poll_ns，并报告 AIP 活动
    // （等待上限是本命令自己的墙钟期限，不是看门狗的无进展预算）。
    protected task poll_step();
      if (shm_wait_sleep_us != 0)
        sw_usleep_dpi(int'(shm_wait_sleep_us));
      #(shm_wait_poll_ns * 1ns);
      aip_activity::tick();
    endtask

    // 等待对端期间让 endpoint 也按 shm_wait_poll_ns 轮询（否则它每 rx_poll_interval 才收一次），最后一个等待者恢复原值。
    protected function void begin_fast_poll();
      if (fast_poll_users++ != 0) return;
      saved_poll_interval = shm_cfg.rx_poll_interval;
      shm_cfg.rx_poll_interval = shm_wait_poll_ns * 1ns;
    endfunction

    protected function void end_fast_poll();
      if (fast_poll_users == 0 || --fast_poll_users != 0) return;
      shm_cfg.rx_poll_interval = saved_poll_interval;
    endfunction

    // 发一个控制信号：按 FIFO 顺序排在已交给 adapter 的 DUT 帧之后，等它交到 switch 才返回（墙钟上限为每个排在前面的帧
    // 加本帧各 shm_tx_timeout_ms），仿真时间每次轮询只推进 shm_wait_poll_ns。
    task signal(string name, string data, output bit ok, output string why);
      eth_seg_seq_item item;
      byte unsigned bytes[$];
      longint unsigned target;
      longint start_ms;
      int unsigned ahead;

      ok = 0;
      if (!check_signal(name, data, why) || !can_use(1, why))
        return;
      repeat (6) bytes.push_back(8'hff);
      bytes.push_back(8'h02);
      repeat (5) bytes.push_back(8'h00);
      bytes.push_back(CTRL_TYPE[15:8]);
      bytes.push_back(CTRL_TYPE[7:0]);
      for (int i = 7; i >= 0; i--)
        bytes.push_back(CTRL_MAGIC[i*8 +: 8]);
      bytes.push_back(name.len());
      foreach (name[i]) bytes.push_back(name[i]);
      bytes.push_back(data.len() >> 8);
      bytes.push_back(data.len() & 8'hff);
      foreach (data[i]) bytes.push_back(data[i]);
      while (bytes.size() < 60) bytes.push_back(8'h00);
      if (bytes.size() + 4 > shm_max_frame) begin
        why = $sformatf("signal '%s' needs a %0d-byte frame with FCS, above %s.shm_max_frame=%0d", name,
                        bytes.size() + 4, param_path, shm_max_frame);
        return;
      end
      item = eth_seg_seq_item::type_id::create("eth_shm_ctrl");
      item.frame_bytes = new[bytes.size()];
      foreach (bytes[i]) item.frame_bytes[i] = bytes[i];
      ahead = adapter.tx_pending_count() + endpoint.tx_pending_count() + (endpoint.tx_is_busy() ? 1 : 0);
      target = endpoint.tx_frames + ahead + 1;
      adapter_ap.write(item);
      if (link_failed(why))
        return;
      ctrl_sent++;
      start_ms = sw_monotonic_ms_dpi();
      while (endpoint.tx_frames < target) begin
        if (link_failed(why))
          return;
        if (sw_monotonic_ms_dpi() - start_ms >= longint'(shm_tx_timeout_ms) * (ahead + 1)) begin
          why = $sformatf("signal '%s' was not handed to the SHM switch within %0d ms", name,
                          shm_tx_timeout_ms * (ahead + 1));
          return;
        end
        poll_step();
      end
      `uvm_info("ETH_SHM_CTRL", $sformatf("%s: sent signal '%s' (%0d data bytes)", param_path, name, data.len()),
                UVM_MEDIUM)
      ok = 1;
    endtask

    // 取一个名为 name 的控制信号：已缓存（对端先发）时立即返回，否则按墙钟等到对端的信号到达或 timeout_ms 到期。
    // 等待期间本端仿真时间每次轮询只推进 shm_wait_poll_ns；超时、传输错误都返回 ok=0 与原因，不挂起。
    task wait_signal(string name, int unsigned timeout_ms, output bit ok, output string data, output string why);
      longint start_ms;
      longint last_ms;
      longint now_ms;
      time t0;

      ok = 0;
      data = "";
      if (!check_signal(name, "", why) || !can_use(0, why))
        return;
      if (timeout_ms == 0) begin
        why = "timeout_ms must be a positive number of milliseconds";
        return;
      end
      t0 = $time;
      start_ms = sw_monotonic_ms_dpi();
      if (start_ms <= 0) begin
        why = "the host monotonic clock is unavailable";
        return;
      end
      last_ms = start_ms;
      now_ms = start_ms;
      begin_fast_poll();
      forever begin
        if (ctrl_box.exists(name) && ctrl_box[name].size() != 0) begin
          data = ctrl_box[name].pop_front();
          ctrl_buffered--;
          ok = 1;
          break;
        end
        if (link_failed(why))
          break;
        now_ms = sw_monotonic_ms_dpi();
        if (now_ms <= 0 || now_ms < last_ms) begin
          why = $sformatf("host monotonic clock error (now %0d ms, previous %0d ms)", now_ms, last_ms);
          break;
        end
        last_ms = now_ms;
        if (now_ms - start_ms >= timeout_ms) begin
          why = $sformatf("no '%s' signal from the peer within %0d ms (wall clock; local time advanced %0d ns)",
                          name, timeout_ms, ($time - t0) / 1ns);
          break;
        end
        poll_step();
      end
      end_fast_poll();
      if (ok)
        `uvm_info("ETH_SHM_CTRL", $sformatf("%s: signal '%s' taken after %0d ms (%0d data bytes)", param_path, name,
                  now_ms - start_ms, data.len()), UVM_LOW)
      else
        `uvm_info("ETH_SHM_CTRL", {param_path, ": wait for '", name, "' failed: ", why}, UVM_LOW)
    endtask

    // endpoint 发布的每帧先经这里：控制帧截下，其余原样交 adapter（同步调用，顺序不变）。
    function void write_shm_link_rx(shm_frame frame);
      if (frame != null && is_ctrl(frame)) begin
        take_ctrl(frame);
        return;
      end
      adapter_rx_ap.write(frame);
    endfunction

    protected function bit is_ctrl(shm_frame frame);
      if (frame.payload.size() < CTRL_HEAD + 3 + 4 || {frame.payload[12], frame.payload[13]} != CTRL_TYPE)
        return 0;
      for (int i = 0; i < 8; i++)
        if (frame.payload[14 + i] != CTRL_MAGIC[(7 - i)*8 +: 8])
          return 0;
      return 1;
    endfunction

    // 校验 FCS 与长度后按名字缓存；FCS 或格式错报 ETH_SHM_CTRL（UVM_ERROR）并丢弃，缓存满（shm_queue_depth 个
    // 未取走的信号）即 fail closed。
    protected function void take_ctrl(shm_frame frame);
      int n = frame.payload.size() - 4;
      int unsigned name_len;
      int unsigned data_len;
      byte unsigned body[];
      bit [31:0] fcs;
      string name;
      string data;

      body = new[n];
      foreach (body[i]) body[i] = frame.payload[i];
      for (int b = 0; b < 4; b++) fcs[b*8 +: 8] = frame.payload[n+b];
      if (eth_seg_codec::crc32(body) != fcs) begin
        drop_ctrl(frame, $sformatf("bad FCS 0x%08h (computed 0x%08h)", fcs, eth_seg_codec::crc32(body)));
        return;
      end
      name_len = body[CTRL_HEAD];
      if (name_len == 0 || name_len > CTRL_NAME_MAX || CTRL_HEAD + 3 + name_len > n) begin
        drop_ctrl(frame, $sformatf("bad name length %0d", name_len));
        return;
      end
      data_len = {body[CTRL_HEAD + 1 + name_len], body[CTRL_HEAD + 2 + name_len]};
      if (data_len > CTRL_DATA_MAX || CTRL_HEAD + 3 + name_len + data_len > n) begin
        drop_ctrl(frame, $sformatf("bad data length %0d", data_len));
        return;
      end
      name = "";
      for (int i = 0; i < name_len; i++) name = {name, string'(body[CTRL_HEAD + 1 + i])};
      data = "";
      for (int i = 0; i < data_len; i++) data = {data, string'(body[CTRL_HEAD + 3 + name_len + i])};
      if (ctrl_buffered >= shm_queue_depth) begin
        shm_runtime::fail($sformatf("%s: control signal '%s' lost: %0d signals are unclaimed (shm_queue_depth=%0d)",
                                    param_path, name, ctrl_buffered, shm_queue_depth));
        return;
      end
      ctrl_box[name].push_back(data);
      ctrl_buffered++;
      ctrl_received++;
      `uvm_info("ETH_SHM_CTRL", $sformatf("%s: received signal '%s' (%0d data bytes)", param_path, name, data_len),
                UVM_MEDIUM)
    endfunction

    protected function void drop_ctrl(shm_frame frame, string why);
      ctrl_dropped++;
      `uvm_error("ETH_SHM_CTRL", $sformatf("%s: control frame from port %0d (%0d bytes) dropped: %s", param_path,
                                            frame.src_port, frame.payload.size(), why))
    endfunction

    // 尚未被 wait 取走的信号名（按名字排序，同名多个时重复列出），供 report 打印。
    function string unclaimed();
      string text = "";
      foreach (ctrl_box[name])
        foreach (ctrl_box[name][i])
          text = {text, (text == "") ? "" : ",", name};
      return text;
    endfunction

    // 命令参数的值：花括号包住的值去掉最外一层（data={a b,c} 即 "a b,c"）；同一键给了两次报错。
    protected static function bit arg_values(aip_cmd handle, string allowed[$], output string value[string],
                                             output string why);
      string keys[$];
      string values[$];
      value.delete();
      if (!aip_cmd::check_arg_keys(handle, allowed))
        return 0;
      if (!aip_cmd::split_arg_pairs(handle.args_in, keys, values, why))
        return 0;
      foreach (keys[i]) begin
        string v = values[i];
        if (value.exists(keys[i])) begin
          why = {keys[i], "= is given more than once"};
          return 0;
        end
        if (v.len() >= 2 && v[0] == "{" && v[v.len() - 1] == "}")
          v = v.substr(1, v.len() - 2);
        value[keys[i]] = v;
      end
      return 1;
    endfunction

    // Tcl eth_shm_signal name=<名字> [data=<文本>]：成功 "OK: eth_shm_signal: <名字>"，失败 status=1 与 "ERROR: ..."。
    static task signal_cmd();
      aip_cmd handle;
      string value[string];
      string why;
      bit ok;

      handle = aip_cmd::get_handle("eth_shm_signal");
      if (!arg_values(handle, '{"name", "data"}, value, why)) begin
        if (why != "") begin
          handle.status = 1;
          handle.result_out = {"ERROR: eth_shm_signal: ", why};
        end
        return;
      end
      if (active == null)
        why = "no SHM link in this simulation (a MAC active agent needs +<agent>.shm=1 inside an SHM cosim)";
      else
        active.signal(value.exists("name") ? value["name"] : "", value.exists("data") ? value["data"] : "", ok, why);
      handle.status = ok ? 0 : 1;
      handle.result_out = ok ? {"OK: eth_shm_signal: ", value["name"]} : {"ERROR: eth_shm_signal: ", why};
    endtask

    // Tcl eth_shm_wait name=<名字> [timeout_ms=<毫秒>]：成功 "OK: eth_shm_wait: <数据>"，超时等失败 status=1 与 "ERROR: ..."；
    // timeout_ms 缺省取 <agent>.shm_wait_timeout_ms。
    static task wait_cmd();
      aip_cmd handle;
      string value[string];
      string why;
      string data;
      longint unsigned timeout_ms;
      bit ok;

      handle = aip_cmd::get_handle("eth_shm_wait");
      if (!arg_values(handle, '{"name", "timeout_ms"}, value, why)) begin
        if (why != "") begin
          handle.status = 1;
          handle.result_out = {"ERROR: eth_shm_wait: ", why};
        end
        return;
      end
      if (active == null)
        why = "no SHM link in this simulation (a MAC active agent needs +<agent>.shm=1 inside an SHM cosim)";
      else if (aip_cmd::parse_uint_arg(value.exists("timeout_ms") ? value["timeout_ms"] : "", 32'hffff_ffff,
                                       active.shm_wait_timeout_ms, timeout_ms, why, "timeout_ms"))
        active.wait_signal(value.exists("name") ? value["name"] : "", timeout_ms, ok, data, why);
      handle.status = ok ? 0 : 1;
      handle.result_out = ok ? {"OK: eth_shm_wait: ", data} : {"ERROR: eth_shm_wait: ", why};
    endtask
  endclass

  // agent 的子组件，build 时取父 agent 的 cfg/sequencer，connect 时自行接 TX monitor、rx_driver.sent_ap 与 hub reset_ap。
  // 拥有一个 shm_endpoint、一个 shm_agent_adapter（binding "default"）与 codec；队列全部有界，满即 fail closed。
  // 时间 0 等 fabric 就绪（墙钟，超时 +SHM_READY_TIMEOUT_MS，失败 fatal），仿真时间不前进，DUT 首帧必在就绪之后。
  class eth_seg_shm_link #(int RATE = 100) extends eth_seg_shm_link_base;
    `uvm_component_param_utils(eth_seg_shm_link#(RATE))

    eth_seg_agent#(RATE) agent;
    eth_seg_config#(RATE) cfg;
    eth_seg_shm_owner_seq#(RATE) owner;
    uvm_analysis_imp_shm_link_tx#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) tx_export;
    uvm_analysis_imp_shm_link_sent#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) sent_export;
    uvm_analysis_imp_shm_link_reset#(eth_seg_reset_notice_t, eth_seg_shm_link#(RATE)) reset_export;

    // sent：交给 adapter 的 TX 帧；received：从 fabric 取出的帧；driven：rx_driver 正沿完成的回灌帧；
    // flushed：复位清除；dropped：格式错误、过短或无目的端口；tx_errors：带 EOP error 或坏 FCS 的 TX 帧。
    int unsigned sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors;
    int unsigned in_flight;              // 已交 rx_driver、尚未完成
    protected int unsigned tx_index;     // TX monitor 帧序号，从 0 计
    protected bit in_reset[2] = '{1, 1}; // 收到 hub 首个复位通知前按复位处理
    protected bit loopback_reported;

    function new(string name, uvm_component parent);
      super.new(name, parent);
      tx_export = new("tx_export", this);
      sent_export = new("sent_export", this);
      reset_export = new("reset_export", this);
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
      if (active != null) begin
        `uvm_fatal("ETH_SHM_CFG", {"only one agent per simulation may set shm=1: ", active.param_path, " and ",
                                   param_path})
        return;
      end
      active = this;
      `aip_cmd_info(eth_shm_signal, "eth_shm", "send an in-band control signal to the SHM peer simulation",
                    "name=<letters/digits/_.:-> [data=<printable text, at most 1000 characters>]")
      `aip_cmd_info(eth_shm_wait, "eth_shm", "wait (wall clock) for a control signal from the SHM peer simulation",
                    "name=<name> [timeout_ms=<positive integer>] (default <agent>.shm_wait_timeout_ms)")
      `aip_uint(param_path, int unsigned, shm_queue_depth, shm_queue_depth)
      `aip_uint(param_path, int unsigned, shm_max_frame, shm_max_frame)
      `aip_uint(param_path, int unsigned, shm_tx_timeout_ms, shm_tx_timeout_ms)
      `aip_uint(param_path, int unsigned, shm_idle_sleep_us, shm_idle_sleep_us)
      `aip_uint(param_path, int unsigned, shm_wait_poll_ns, shm_wait_poll_ns)
      `aip_uint(param_path, int unsigned, shm_wait_sleep_us, shm_wait_sleep_us)
      `aip_uint(param_path, int unsigned, shm_wait_timeout_ms, shm_wait_timeout_ms)
      if (shm_wait_poll_ns == 0 || shm_wait_sleep_us > shm_endpoint_config::MAX_DPI_SLEEP_US || shm_wait_timeout_ms == 0) begin
        `uvm_fatal("ETH_SHM_CFG", $sformatf({"%s: invalid control-signal waits shm_wait_poll_ns=%0d (>0) ",
                                             "shm_wait_sleep_us=%0d (<1000000) shm_wait_timeout_ms=%0d (>0)"},
                                            param_path, shm_wait_poll_ns, shm_wait_sleep_us, shm_wait_timeout_ms))
        return;
      end
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

    // RX 能力时 endpoint 的帧先经 rx_export 截下控制帧，再交 adapter；agent 自己的 sequencer 与 adapter 解码队列
    // 登记为 binding "default"，endpoint 在 end_of_elaboration 选中。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (endpoint == null) return;
      agent.tx_monitor.item_collected_port.connect(tx_export);
      agent.rx_driver.sent_ap.connect(sent_export);
      agent.monitor_hub.reset_ap.connect(reset_export);
      adapter_ap.connect(adapter.monitor_export);
      if (shm_cfg.direction != SHM_RX_ONLY) adapter.shm_tx_ap.connect(endpoint.tx_export);
      if (shm_cfg.direction != SHM_TX_ONLY) begin
        endpoint.rx_ap.connect(rx_export);
        adapter_rx_ap.connect(adapter.shm_rx_export);
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

    // 控制信号另计 ctrl_sent/ctrl_received/ctrl_dropped；结束时仍未被 wait 取走的信号名列在 ctrl_unclaimed。
    function void report_phase(uvm_phase phase);
      string left;
      super.report_phase(phase);
      if (endpoint == null) return;
      left = unclaimed();
      `uvm_info("ETH_SHM", $sformatf({"%s: sent=%0d received=%0d driven=%0d flushed=%0d dropped=%0d tx_errors=%0d pending=%0d ",
                                      "ctrl_sent=%0d ctrl_received=%0d ctrl_dropped=%0d ctrl_unclaimed=%s"},
                param_path, sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors,
                pending(), ctrl_sent, ctrl_received, ctrl_dropped, (left == "") ? "none" : left), UVM_LOW)
    endfunction
  endclass

  // agent 只认名字（基础包不依赖本包），三档速率各登记一个。
  typedef uvm_component_registry #(eth_seg_shm_link#(100), "eth_seg_shm_link_100") eth_seg_shm_link_100_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(200), "eth_seg_shm_link_200") eth_seg_shm_link_200_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(400), "eth_seg_shm_link_400") eth_seg_shm_link_400_registry;

  // 两个仿真之间的握手命令（目标是本进程唯一的 shm=1 链路），说明见 eth_seg_shm_link_base::signal_cmd/wait_cmd。
  `aip_cmd_task(eth_shm_signal, eth_seg_shm_link_base::signal_cmd)
  `aip_cmd_task(eth_shm_wait, eth_seg_shm_link_base::wait_cmd)
endpackage
`endif
