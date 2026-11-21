// 可选 SHM 联仿绑定（依赖 shm_work 的 shm_uvm_pkg 与 shm_aip_pkg）：MAC active agent 置 shm=1 时按名字创建
// eth_seg_shm_link_<RATE>。TX monitor 在 EOP 发布的整帧编码进 SHM fabric，fabric 收到的帧经 agent 自身
// sequencer/rx_driver 回灌 RX，与 loopback 同一路径。一个仿真可有任意多个 shm=1 的 agent（速率可以不同），共用进程内
// 唯一的 endpoint 与 binding "default"：不带参数的 eth_seg_shm_hub 把各链路复用到这一个端口上，每帧带链路名，接收端交给
// 同名链路；端口、方向与就绪超时取自 SimFlow def_shm_cosim 生成的 +SHM_* plusarg。
// 另有节点级的带内控制通道（两个仿真之间的握手）：Tcl eth_shm_signal/eth_shm_wait，帧格式与语义见 eth_seg_shm_hub。
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
  `uvm_analysis_imp_decl(_shm_hub_rx)

  typedef class eth_seg_shm_hub;
  typedef class eth_seg_shm_link_base;

  // SHM 载荷（两端须是同一版本的 eth_seg_agent）：首字节 'E'，次字节为类型。
  //   'D' 数据帧：链路名长度（1B）、链路名，再接线上帧（DA..payload，不含前导）与 4 字节 FCS；接收端交给同名链路。
  //   'C' 控制帧：控制帧本体（见 eth_seg_shm_hub）与 4 字节 FCS，属于节点，不属于任何链路。
  localparam byte unsigned ETH_SHM_MARK = 8'h45;       // 'E'
  localparam byte unsigned ETH_SHM_KIND_DATA = 8'h44;  // 'D'
  localparam byte unsigned ETH_SHM_KIND_CTRL = 8'h43;  // 'C'
  localparam int unsigned ETH_SHM_NAME_MAX = 64;       // 链路名与控制信号名的长度上限

  // SHM 载荷头的生成与解析（链路、hub 与 codec 共用）。
  class eth_seg_shm_fmt;
    // 控制信号名的字符只允许字母、数字与 _ . : -。
    static function bit name_chars_ok(string name);
      foreach (name[i]) begin
        byte c = name[i];
        if (!((c >= 8'h30 && c <= 8'h39) || (c >= 8'h41 && c <= 8'h5a) || (c >= 8'h61 && c <= 8'h7a) ||
              c inside {8'h5f, 8'h2e, 8'h3a, 8'h2d}))
          return 0;
      end
      return 1;
    endfunction

    // 链路名 1..64 个字符，只含字母、数字与 _ . -（经 aip 读参，不用会被当作候选或范围的逗号、冒号与方括号）。
    static function bit link_name_ok(string name);
      if (name.len() == 0 || name.len() > ETH_SHM_NAME_MAX) return 0;
      foreach (name[i]) begin
        byte c = name[i];
        if (!((c >= 8'h30 && c <= 8'h39) || (c >= 8'h41 && c <= 8'h5a) || (c >= 8'h61 && c <= 8'h7a) ||
              c inside {8'h5f, 8'h2e, 8'h2d}))
          return 0;
      end
      return 1;
    endfunction

    // 数据帧头长度：'E' 'D'、名字长度与名字。
    static function int unsigned data_head_len(string link);
      return 3 + link.len();
    endfunction

    // 解析载荷头：kind 为类型，数据帧另给链路名；offset 是线上帧（控制帧本体）的起点。格式不对返回 0 与原因。
    static function bit parse_head(shm_frame frame, output byte unsigned kind, output string link, output int offset,
                                   output string why);
      int unsigned len;
      kind = 0;
      link = "";
      offset = 0;
      why = "";
      if (frame == null || frame.payload.size() < 2) begin
        why = "shorter than the 2-byte header";
        return 0;
      end
      if (frame.payload[0] != ETH_SHM_MARK) begin
        why = $sformatf("first byte 0x%02h is not the eth_seg_agent SHM marker 0x%02h", frame.payload[0], ETH_SHM_MARK);
        return 0;
      end
      kind = frame.payload[1];
      if (kind == ETH_SHM_KIND_CTRL) begin
        offset = 2;
        return 1;
      end
      if (kind != ETH_SHM_KIND_DATA) begin
        why = $sformatf("unknown frame type 0x%02h", kind);
        return 0;
      end
      len = (frame.payload.size() > 2) ? frame.payload[2] : 0;
      if (len == 0 || len > ETH_SHM_NAME_MAX || frame.payload.size() < 3 + len) begin
        why = $sformatf("bad link name length %0d", len);
        return 0;
      end
      for (int i = 0; i < len; i++) link = {link, string'(frame.payload[3 + i])};
      if (link.len() != len || !link_name_ok(link)) begin
        why = "link name has characters other than letters, digits and _ . -";
        return 0;
      end
      offset = 3 + len;
      return 1;
    endfunction
  endclass

  // adapter 的事务：hub 中的链路序号加一帧。TX 时为 monitor 帧（link 为 -1 表示控制帧），RX 时为解码出的帧。
  class eth_seg_shm_item extends uvm_sequence_item;
    `uvm_object_utils(eth_seg_shm_item)

    int link = -1;
    eth_seg_seq_item item;

    function new(string name = "eth_seg_shm_item");
      super.new(name);
    endfunction
  endclass

  // 线上帧与 FCS：TX 已带 FCS（skip_crc）时原样保留（坏 FCS 照旧），否则补正确 CRC；EOP error 帧把 FCS 改成正确 CRC 取反，
  // 像 MAC 发错误帧那样让对端必报 FCS 错。接收端按本链路的 include_fcs 保留或剥离 FCS，rx_fcs_error 只看载荷 FCS 是否正确；
  // 两端格式各自独立。数据帧头里的链路名取自 hub 的链路表，接收端按名字找回本端链路序号。
  class eth_seg_shm_codec extends shm_codec#(eth_seg_shm_item, eth_seg_shm_item);
    `uvm_object_utils(eth_seg_shm_codec)

    eth_seg_shm_hub hub;             // 链路表：名字与各链路接收端的 include_fcs
    int unsigned max_frame = 2032;   // SHM 载荷上限（头 + 帧 + FCS），等于 endpoint max_packet_size

    function new(string name = "eth_seg_shm_codec");
      super.new(name);
    endfunction

    virtual function bit encode(eth_seg_shm_item item, ref shm_frame frame);
      eth_seg_seq_item eth;
      byte unsigned head[$];
      byte unsigned body[];
      bit [31:0] crc;
      int n;
      frame = null;
      if (item == null || item.item == null || item.item.aborted || hub == null) return 0;
      eth = item.item;
      if (item.link < 0) head = {ETH_SHM_MARK, ETH_SHM_KIND_CTRL};
      else begin
        string name;
        if (item.link >= hub.links.size()) return 0;
        name = hub.links[item.link].link_name;
        head = {ETH_SHM_MARK, ETH_SHM_KIND_DATA, byte'(name.len())};
        foreach (name[i]) head.push_back(name[i]);
      end
      n = eth.frame_bytes.size() - (eth.fcs_present ? 4 : 0);
      if (n < 9 || head.size() + n + 4 > max_frame) return 0;
      body = new[n];
      foreach (body[i]) body[i] = eth.frame_bytes[i];
      crc = eth_seg_codec::crc32(body);
      frame = shm_frame::type_id::create("eth_seg_shm_frame");
      if (frame == null) return 0;
      frame.payload = new[head.size() + n + 4];
      foreach (head[i]) frame.payload[i] = head[i];
      foreach (body[i]) frame.payload[head.size() + i] = body[i];
      for (int b = 0; b < 4; b++)
        frame.payload[head.size() + n + b] = eth.inject_error ? ~crc[b*8 +: 8] :
                                              eth.fcs_present ? eth.frame_bytes[n+b] : crc[b*8 +: 8];
      return 1;
    endfunction

    // 一帧解成一个 RX 事务（带链路序号）；不是本端已有链路的数据帧、剥离 FCS 后不足 9B（rx_driver 下限）或超过 max_frame
    // 时失败，由 adapter fail closed（链路名不存在已先由 hub 报告）。
    virtual function bit decode(shm_frame frame, ref eth_seg_shm_item items[$]);
      eth_seg_shm_item w;
      eth_seg_seq_item eth;
      byte unsigned body[];
      bit [31:0] fcs;
      int index;
      int offset;
      int n;
      items.delete();
      if (frame == null || hub == null || frame.payload.size() > max_frame) return 0;
      index = hub.data_link(frame, offset);
      if (index < 0) return 0;
      n = frame.payload.size() - offset - 4;
      if (n < 9) return 0;
      body = new[n];
      foreach (body[i]) body[i] = frame.payload[offset + i];
      for (int b = 0; b < 4; b++) fcs[b*8 +: 8] = frame.payload[offset + n + b];
      eth = eth_seg_seq_item::type_id::create("eth_seg_shm_rx");
      w = eth_seg_shm_item::type_id::create("eth_seg_shm_rx_item");
      if (eth == null || w == null) return 0;
      if (hub.links[index].rx_include_fcs) begin
        eth.frame_bytes = new[n + 4];
        foreach (eth.frame_bytes[i]) eth.frame_bytes[i] = frame.payload[offset + i];
      end
      else eth.frame_bytes = body;
      eth.fcs_present = hub.links[index].rx_include_fcs;
      eth.rx_fcs_error = (eth_seg_codec::crc32(body) != fcs);
      eth.direction = ETH_SEG_RX;
      w.link = index;
      w.item = eth;
      items.push_back(w);
      return 1;
    endfunction
  endclass

  // 常驻 owner sequence：agent sequencer 上唯一消费本链路解码队列的 sequence，一批即一帧，与用户 RX sequence 按帧交错。
  // RX 复位期间先等复位释放再驱动（两进程没有时间同步，早到的帧不算复位期间的帧）；grant 前后检查复位代次，
  // 复位清掉的帧标 aborted 交给 rx_driver 丢弃（同 loopback）。等帧期间不提 objection，像 loopback 一样空闲阻塞；
  // kill 时按 shm_work 模板撤销消费者占用。
  class eth_seg_shm_owner_seq extends uvm_sequence #(eth_seg_seq_item);
    `uvm_object_utils(eth_seg_shm_owner_seq)
    typedef shm_item_source #(eth_seg_seq_item) source_t;
    typedef shm_item_batch #(eth_seg_seq_item) batch_t;

    eth_seg_shm_link_base link;
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

  // 一条 SHM 链路与速率无关的部分：名字、参数、计数、本链路的解码队列与复位状态；hub 经此接口分发与统计。
  virtual class eth_seg_shm_link_base extends uvm_component;
    typedef shm_item_source #(eth_seg_seq_item) source_t;
    typedef shm_item_batch #(eth_seg_seq_item) batch_t;

    string param_path;      // aip 参数路径，即 agent 登记名
    string link_name;       // 链路名：缺省 agent 叶名，+<agent>.shm_link 覆盖；本仿真内唯一，与对端同名链路相连
    int hub_index = -1;     // 在 hub 链路表中的序号
    bit rx_include_fcs;     // 本链路 agent 的 cfg.include_fcs（codec 按它保留或剥离收到的 FCS）
    eth_seg_shm_hub hub;
    shm_endpoint endpoint;  // 本进程唯一的 endpoint（与 hub.endpoint 相同）
    source_t source;        // 本链路的解码队列：hub 分发进来，owner sequence 取出
    eth_seg_shm_owner_seq owner;

    // 按 agent 路径经 aip 读取（+<agent>.<名>）。shm_link 只属于本链路；其余是节点级参数，同一仿真的 shm=1 agent 共用一个
    // endpoint，各链路的值须相同（不同即 build fatal，可用叶名 +shm_xxx=… 一次给全部 agent）：队列深度（adapter/endpoint 各级、
    // 每条链路的解码队列与控制信号缓存）、SHM 载荷上限（链路头 + 帧 + FCS，须 ≤ fabric slot_size-16）、fabric 满或对端暂停时
    // 发送重试的墙钟上限、接收空闲时每次轮询的宿主休眠；控制通道等待时每次轮询推进的仿真时间（等待期间 endpoint 也按它轮询）
    // 与宿主休眠、eth_shm_wait 缺省的墙钟上限；开始时是否与对端交换并核对链路名集合。
    string shm_link;
    int unsigned shm_queue_depth = 256;
    int unsigned shm_max_frame = 2032;
    int unsigned shm_tx_timeout_ms = 1000;
    int unsigned shm_idle_sleep_us = 0;
    int unsigned shm_wait_poll_ns = 1;
    int unsigned shm_wait_sleep_us = 1000;
    int unsigned shm_wait_timeout_ms = 600000;
    bit shm_link_check = 0;

    // sent：交给 adapter 的 TX 帧；received：从本链路解码队列取出的帧；driven：rx_driver 正沿完成的回灌帧；
    // flushed：复位清除；dropped：格式错误、过短或无目的端口；tx_errors：带 EOP error 或坏 FCS 的 TX 帧。
    int unsigned sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors;
    int unsigned in_flight;              // 已交 rx_driver、尚未完成
    protected bit in_reset[2] = '{1, 1}; // 收到 hub 首个复位通知前按复位处理

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function bit rx_in_reset();
      return in_reset[ETH_SEG_RX];
    endfunction

    // owner 每帧驱动前调用：RX 复位期间阻塞到释放（与 loopback 的 wait_frame 一样是无 objection 的空闲等待）。
    task wait_rx_ready();
      wait (!in_reset[ETH_SEG_RX]);
    endtask

    // hub 分发一帧：本链路解码队列已有 shm_queue_depth 帧未取走即 fail closed。
    function void deliver(eth_seg_seq_item item, int src_port);
      batch_t batch;
      if (source == null) begin
        shm_runtime::fail({param_path, ": SHM frame for link '", link_name, "', which does not receive (TX_ONLY)"});
        return;
      end
      if (source.pending_count() >= shm_queue_depth) begin
        shm_runtime::fail($sformatf("%s: decoded source FIFO is full (link %s, shm_queue_depth=%0d)", param_path, link_name,
                                    shm_queue_depth));
        return;
      end
      batch = new("eth_seg_shm_link_batch");
      batch.src_port = src_port;
      batch.items.push_back(item);
      void'(source.try_put(batch));
    endfunction

    // 本链路解码队列与已交 rx_driver 未完成的帧。
    function int unsigned pending();
      return ((source == null) ? 0 : source.pending_count()) + ((owner != null && owner.batch_held) ? 1 : 0) + in_flight;
    endfunction

    // 本链路已空，且共用的 adapter/endpoint 队列也已空（尚未分发的帧可能属于本链路）。
    function bit is_idle();
      return pending() == 0 && (hub == null || hub.is_idle());
    endfunction
  endclass

  // 进程内唯一的 SHM hub（首条 shm=1 链路 build 时创建为它的子组件）：持有 endpoint、adapter（binding "default"）与 codec，
  // 按链路名复用各链路，并承载两个仿真之间的带内控制通道。endpoint 与 adapter 是首条链路的子组件（只有一条链路时路径与
  // 统计行和多链路之前相同）；adapter 的解码队列由 hub 唯一消费，逐帧交给同名链路的解码队列；本端没有的链路名即 fail closed。
  // 控制帧是普通以太网帧：DA 全 1、SA 02:00:00:00:00:00、EtherType 0x88B5（IEEE 本地实验类型），载荷依次为魔数
  // "ETHSHMC1"、名字长度（1B）、名字、数据长度（2B，大端）与数据，不足 60B 补零，FCS 由 codec 补正确 CRC，SHM 头类型 'C'。
  // 它与各链路的 DUT 帧走同一条 TX 队列（保序，先发的帧先到），对端 hub 在 endpoint 与 adapter 之间截下，不交给 adapter、
  // 不进 DUT，按名字排队缓存，等本端 wait 取走。控制帧计入 endpoint 的收发计数（SHM_ENDPOINT_COUNTERS、shm_transport
  // 检查器），不计入各链路的 sent/received/driven。保留名 "#links"（用户名字不允许 #）用于开始时交换链路名集合。
  class eth_seg_shm_hub extends uvm_component;
    `uvm_component_utils(eth_seg_shm_hub)
    typedef shm_agent_adapter #(eth_seg_shm_item, eth_seg_shm_item) adapter_t;
    typedef shm_item_source #(eth_seg_shm_item) source_t;
    typedef shm_item_batch #(eth_seg_shm_item) batch_t;
    localparam bit [15:0] CTRL_TYPE = 16'h88b5;
    localparam bit [63:0] CTRL_MAGIC = 64'h4554_4853_484d_4331;  // "ETHSHMC1"
    localparam int unsigned CTRL_HEAD = 22;                      // DA/SA/EtherType 14B + 魔数 8B
    localparam int unsigned CTRL_NAME_MAX = ETH_SHM_NAME_MAX;
    // 数据上限给 Tcl 结果 "OK: eth_shm_wait: <数据>" 留出余量（AIP 命令与结果各限 1024B）。
    localparam int unsigned CTRL_DATA_MAX = 1000;
    localparam string LINKS_SIGNAL = "#links";

    // 本进程的 hub，也是 eth_shm_signal/eth_shm_wait 的目标；没有 shm=1 的 agent 时为 null。
    static eth_seg_shm_hub inst;

    eth_seg_shm_link_base links[$];       // build 顺序
    protected int link_index[string];     // 链路名 → links 序号

    // 节点级参数：取自首条链路，其余链路登记时核对相同（含义见 eth_seg_shm_link_base）。
    int unsigned shm_queue_depth, shm_max_frame, shm_tx_timeout_ms, shm_idle_sleep_us;
    int unsigned shm_wait_poll_ns, shm_wait_sleep_us, shm_wait_timeout_ms;
    bit shm_link_check;

    shm_endpoint_config shm_cfg;
    shm_endpoint endpoint;
    adapter_t adapter;
    eth_seg_shm_codec codec;
    uvm_sequencer #(eth_seg_shm_item) rx_sqr;                             // binding "default" 的 RX 登记锚点
    uvm_analysis_port#(eth_seg_shm_item) adapter_ap;                      // 各链路 TX 帧与控制帧 → adapter
    uvm_analysis_imp_shm_hub_rx#(shm_frame, eth_seg_shm_hub) rx_export;   // endpoint.rx_ap → 截下控制帧、核对链路名
    uvm_analysis_port#(shm_frame) adapter_rx_ap;                          // 其余帧 → adapter.shm_rx_export

    // ctrl_sent：已交给 switch 的控制信号；ctrl_received：收下并缓存的；ctrl_dropped：FCS 或格式错误而丢弃的。
    // 链路名集合的交换帧不计入这三项。
    int unsigned ctrl_sent, ctrl_received, ctrl_dropped;
    bit ready;              // fabric 已就绪（时间 0 等到）
    bit ready_done;         // 就绪等待已返回（成功或失败）
    bit peer_links_seen;    // 已收到并核对对端的链路名集合
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

    // 链路 build 时调用：首条链路创建 hub 与共用组件，之后每条链路登记（名字重复或节点级参数不同即 fatal，返回 null）。
    static function eth_seg_shm_hub attach(eth_seg_shm_link_base link);
      if (inst == null) begin
        inst = eth_seg_shm_hub::type_id::create("shm_hub", link);
        if (!inst.setup(link)) return null;
      end
      if (!inst.add_link(link)) return null;
      return inst;
    endfunction

    // 节点级参数取首条链路的值；endpoint 与 adapter 在首条链路的 build_phase 内创建为它的子组件，随后由 UVM 构建。
    protected function bit setup(eth_seg_shm_link_base first);
      shm_queue_depth = first.shm_queue_depth;
      shm_max_frame = first.shm_max_frame;
      shm_tx_timeout_ms = first.shm_tx_timeout_ms;
      shm_idle_sleep_us = first.shm_idle_sleep_us;
      shm_wait_poll_ns = first.shm_wait_poll_ns;
      shm_wait_sleep_us = first.shm_wait_sleep_us;
      shm_wait_timeout_ms = first.shm_wait_timeout_ms;
      shm_link_check = first.shm_link_check;
      `aip_cmd_info(eth_shm_signal, "eth_shm", "send an in-band control signal to the SHM peer simulation",
                    "name=<letters/digits/_.:-> [data=<printable text, at most 1000 characters>]")
      `aip_cmd_info(eth_shm_wait, "eth_shm", "wait (wall clock) for a control signal from the SHM peer simulation",
                    "name=<name> [timeout_ms=<positive integer>] (default <agent>.shm_wait_timeout_ms)")
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
        `uvm_fatal_context("ETH_SHM_CFG", $sformatf({"%s: invalid SHM settings shm_queue_depth=%0d (>0) shm_max_frame=%0d ",
                                                     "(1..16368) shm_tx_timeout_ms=%0d (>0) shm_idle_sleep_us=%0d (<1000000)"},
                                                    first.param_path, shm_queue_depth, shm_max_frame, shm_tx_timeout_ms,
                                                    shm_idle_sleep_us), first)
        return 0;
      end
      endpoint = shm_endpoint::type_id::create("endpoint", first);
      endpoint.cfg = shm_cfg;
      adapter = adapter_t::type_id::create("adapter", first);
      adapter.cfg = shm_cfg;
      adapter.binding_name = "default";
      adapter.source_depth = shm_queue_depth;
      codec = eth_seg_shm_codec::type_id::create("codec");
      codec.hub = this;
      codec.max_frame = shm_max_frame;
      adapter.codec = codec;
      return 1;
    endfunction

    // 节点级参数名与取值（顺序固定），用于逐链路比对。
    protected static function void node_params(eth_seg_shm_link_base l, ref string names[$],
                                               ref longint unsigned values[$]);
      names = {"shm_queue_depth", "shm_max_frame", "shm_tx_timeout_ms", "shm_idle_sleep_us", "shm_wait_poll_ns",
               "shm_wait_sleep_us", "shm_wait_timeout_ms", "shm_link_check"};
      values = {l.shm_queue_depth, l.shm_max_frame, l.shm_tx_timeout_ms, l.shm_idle_sleep_us, l.shm_wait_poll_ns,
                l.shm_wait_sleep_us, l.shm_wait_timeout_ms, longint'(l.shm_link_check)};
    endfunction

    protected function bit add_link(eth_seg_shm_link_base link);
      string names[$];
      string first_names[$];
      longint unsigned values[$];
      longint unsigned first_values[$];
      if (link_index.exists(link.link_name)) begin
        `uvm_fatal_context("ETH_SHM_CFG", $sformatf({"%s: SHM link name '%s' is already used by %s; link names must be unique ",
                                                     "within one simulation (rename one with +<agent>.shm_link=<name>)"},
                                                    link.param_path, link.link_name,
                                                    links[link_index[link.link_name]].param_path), link)
        return 0;
      end
      if (links.size() != 0) begin
        node_params(links[0], first_names, first_values);
        node_params(link, names, values);
        foreach (names[i])
          if (values[i] != first_values[i]) begin
            `uvm_fatal_context("ETH_SHM_CFG", $sformatf({"%s.%s=%0d differs from %s.%s=%0d: all shm=1 agents of one ",
                                                         "simulation share one SHM endpoint, so every SHM parameter except ",
                                                         "shm_link must be equal (give each agent the value, or use the leaf ",
                                                         "form +%s=<value>)"}, link.param_path, names[i], values[i],
                                                        links[0].param_path, names[i], first_values[i], names[i]), link)
            return 0;
          end
      end
      link.hub_index = links.size();
      link_index[link.link_name] = links.size();
      links.push_back(link);
      return 1;
    endfunction

    // 链路名按字典序以逗号连接，用于诊断与链路名集合的交换。
    function string link_names();
      string names[$];
      string text = "";
      foreach (links[i]) names.push_back(links[i].link_name);
      names.sort();
      foreach (names[i]) text = {text, (i == 0) ? "" : ",", names[i]};
      return text;
    endfunction

    // 诊断里的主语：只有一条链路时为其 agent 路径（与多链路之前相同），否则列出链路名。
    function string subject();
      if (links.size() == 1) return links[0].param_path;
      return {"SHM links ", link_names()};
    endfunction

    // 控制通道等诊断的上报者：只有一条链路时为该链路组件（日志与多链路之前相同），否则为 hub。
    function uvm_report_object reporter();
      if (links.size() == 1) return links[0];
      return this;
    endfunction

    // 解析为本端某条链路的数据帧时返回其序号与线上帧起点，否则返回 -1。
    function int data_link(shm_frame frame, output int offset);
      byte unsigned kind;
      string name;
      string why;
      if (!eth_seg_shm_fmt::parse_head(frame, kind, name, offset, why) || kind != ETH_SHM_KIND_DATA ||
          !link_index.exists(name))
        return -1;
      return link_index[name];
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (endpoint != null && shm_cfg.direction != SHM_TX_ONLY)
        rx_sqr = uvm_sequencer#(eth_seg_shm_item)::type_id::create("rx_sqr", this);
    endfunction

    // RX 能力时 endpoint 的帧先经 rx_export 截下控制帧并核对链路名，再交 adapter；adapter 解码队列与 rx_sqr 登记为
    // binding "default"，endpoint 在 end_of_elaboration 选中。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (endpoint == null) return;
      adapter_ap.connect(adapter.monitor_export);
      if (shm_cfg.direction != SHM_RX_ONLY) adapter.shm_tx_ap.connect(endpoint.tx_export);
      if (shm_cfg.direction != SHM_TX_ONLY) begin
        endpoint.rx_ap.connect(rx_export);
        adapter_rx_ap.connect(adapter.shm_rx_export);
        void'(shm_binding_registry::register_binding("default", adapter, rx_sqr, adapter.get_item_source(),
                                                     shm_cfg.direction != SHM_RX_ONLY, 1));
      end
      else
        void'(shm_binding_registry::register_binding("default", adapter, null, null, 1, 0));
    endfunction

    // SHM 收发活动推进 AIP 活动计数，供 end_test 空闲判断与 Tcl ACK 等待使用。多条链路可能在同一时刻各交出一帧，
    // 共用队列的深度不得小于链路数。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (endpoint == null) return;
      if (links.size() > 1 && shm_queue_depth < links.size())
        `uvm_fatal("ETH_SHM_CFG", $sformatf({"shm_queue_depth=%0d is below the number of shm=1 links (%0d: %s); every link ",
                                             "may hand over a frame in the same time step"}, shm_queue_depth, links.size(),
                                            link_names()))
      install_shm_aip_hooks();
    endfunction

    // 时间 0 等 fabric 就绪（墙钟，超时 +SHM_READY_TIMEOUT_MS，失败 fatal），仿真时间不前进，DUT 首帧必在就绪之后；
    // 打开 shm_link_check 时先把本端链路名集合发给对端，再常驻分发解码队列。
    task run_phase(uvm_phase phase);
      bit ok;
      if (endpoint == null) return;
      shm_runtime::ensure_ready(ok);
      ready = ok;
      ready_done = 1;
      if (!ok) return;
      if (shm_link_check && shm_cfg.direction != SHM_RX_ONLY) send_link_list();
      if (shm_cfg.direction != SHM_TX_ONLY) dispatch();
    endtask

    // 链路 run_phase 在时间 0 调用：等 hub 的就绪等待返回（它以 +SHM_READY_TIMEOUT_MS 为墙钟上限，失败即 fatal）。
    task wait_ready(output bit ok);
      wait (ready_done);
      ok = ready;
    endtask

    // adapter 解码队列的唯一消费者：逐批按链路序号交给对应链路（零时间，链路解码队列满即 fail closed）。
    protected task dispatch();
      source_t src = adapter.get_item_source();
      forever begin
        batch_t batch;
        src.get(batch);
        if (batch == null) begin
          shm_runtime::fail({subject(), ": SHM decoded source returned no batch"});
          return;
        end
        foreach (batch.items[i]) begin
          eth_seg_shm_item w = batch.items[i];
          if (w == null || w.item == null || w.link < 0 || w.link >= links.size()) begin
            shm_runtime::fail({subject(), ": SHM decoded source returned a frame without a link"});
            return;
          end
          links[w.link].deliver(w.item, batch.src_port);
        end
        src.release_batch();
      end
    endtask

    // 链路的 TX 帧：带上链路序号交 adapter（满即 fatal）。
    function void send(int link, eth_seg_seq_item item);
      eth_seg_shm_item w = eth_seg_shm_item::type_id::create("eth_seg_shm_tx");
      w.link = link;
      w.item = item;
      adapter_ap.write(w);
    endfunction

    // 某条链路 TX 复位断言：只从共用的 adapter TX 队列移除该链路的帧（endpoint 已收下的帧视为已上线路），
    // 其余链路的帧与控制帧按原顺序保留；返回移除的帧数。
    function int unsigned flush_tx(int link);
      shm_frame keep[$];
      shm_frame frame;
      int unsigned removed;
      if (adapter == null || adapter.tx_fifo == null) return 0;
      while (adapter.tx_fifo.try_get(frame)) begin
        int offset;
        if (data_link(frame, offset) == link) removed++;
        else keep.push_back(frame);
      end
      foreach (keep[i]) void'(adapter.tx_fifo.try_put(keep[i]));
      return removed;
    endfunction

    // 共用队列已空：adapter 与 endpoint 的 TX 队列和在途帧，endpoint 的 RX 队列与尚未分发的解码队列。
    function bit is_idle();
      shm_item_source_base src = (adapter == null) ? null : adapter.get_item_source();
      return (adapter == null || adapter.tx_pending_count() == 0) &&
             (endpoint == null || (endpoint.tx_pending_count() == 0 && !endpoint.tx_is_busy() &&
                                   (endpoint.rx_fifo == null || endpoint.rx_fifo.used() == 0))) &&
             (src == null || src.pending_count() == 0);
    endfunction

    // endpoint 发布的每帧先经这里（同步调用，顺序不变）：控制帧截下；数据帧的链路名本端没有即 fail closed，
    // 不丢弃、也不交给别的链路；格式不对（对端不是同一版本的 eth_seg_agent）同样 fail closed。
    function void write_shm_hub_rx(shm_frame frame);
      byte unsigned kind;
      string name;
      string why;
      int offset;
      if (!eth_seg_shm_fmt::parse_head(frame, kind, name, offset, why)) begin
        fail_closed("ETH_SHM_FORMAT", $sformatf({"%s: SHM frame from port %0d (%0d bytes) is not an eth_seg_agent SHM frame: ",
                                                 "%s; both nodes must run the same eth_seg_agent version"}, subject(),
                                                (frame == null) ? -1 : frame.src_port,
                                                (frame == null) ? 0 : frame.payload.size(), why));
        return;
      end
      if (kind == ETH_SHM_KIND_CTRL) begin
        take_ctrl(frame, offset);
        return;
      end
      if (!link_index.exists(name)) begin
        fail_closed("ETH_SHM_LINK", $sformatf({"SHM frame from port %0d names link '%s', but this simulation has no shm=1 agent ",
                                               "with that link name (local links: %s); both nodes need the same link names ",
                                               "(default: the agent leaf name; override: +<agent>.shm_link=<name>)"},
                                              frame.src_port, name, link_names()));
        return;
      end
      adapter_rx_ap.write(frame);
    endfunction

    // 锁存进程级首错（控制通道等待与 shm_transport 检查器随之失败）并以指定 ID fatal。
    protected function void fail_closed(string id, string detail);
      shm_runtime::latch_failure(detail);
      `uvm_fatal_context(id, detail, reporter())
    endfunction

    // 名字 1..64 个字符，只含字母、数字与 _ . : -；数据至多 1000 个可打印 ASCII 字符（0x20..0x7e），可以为空。
    static function bit check_signal(string name, string data, output string why);
      why = "";
      if (name.len() == 0 || name.len() > CTRL_NAME_MAX) begin
        why = $sformatf("name='%s': needs 1..%0d characters", name, CTRL_NAME_MAX);
        return 0;
      end
      if (!eth_seg_shm_fmt::name_chars_ok(name)) begin
        why = {"name=", name, ": only letters, digits and _ . : - are allowed"};
        return 0;
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

    // 能否收发控制帧：fabric 已就绪、没有锁存的传输错误，且本节点有对应方向。
    protected function bit can_use(bit tx, output string why);
      why = "";
      if (endpoint == null || adapter == null)
        why = {subject(), ": the SHM link has no endpoint (needs +SHM_ENABLE=1 from SimFlow def_shm_cosim)"};
      else if (link_failed(why))
        return 0;
      else if (!ready)
        why = {subject(), ": the SHM fabric is not ready yet"};
      else if (tx && shm_cfg.direction == SHM_RX_ONLY)
        why = {subject(), ": this SHM node has no destination (RX_ONLY)"};
      else if (!tx && shm_cfg.direction == SHM_TX_ONLY)
        why = {subject(), ": this SHM node does not receive (TX_ONLY)"};
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

    // 控制帧（未经 SHM 头与 FCS）：超过 shm_max_frame 时返回 null 与原因。
    protected function eth_seg_seq_item ctrl_item(string name, string data, output string why);
      eth_seg_seq_item item;
      byte unsigned bytes[$];
      why = "";
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
      if (2 + bytes.size() + 4 > shm_max_frame) begin
        why = $sformatf("signal '%s' needs a %0d-byte SHM frame, above %s.shm_max_frame=%0d", name, 2 + bytes.size() + 4,
                        links[0].param_path, shm_max_frame);
        return null;
      end
      item = eth_seg_seq_item::type_id::create("eth_shm_ctrl");
      item.frame_bytes = new[bytes.size()];
      foreach (bytes[i]) item.frame_bytes[i] = bytes[i];
      return item;
    endfunction

    // 发一个控制信号：按 FIFO 顺序排在已交给 adapter 的 DUT 帧之后，等它交到 switch 才返回（墙钟上限为每个排在前面的帧
    // 加本帧各 shm_tx_timeout_ms），仿真时间每次轮询只推进 shm_wait_poll_ns。
    task signal(string name, string data, output bit ok, output string why);
      eth_seg_seq_item item;
      longint unsigned target;
      longint start_ms;
      int unsigned ahead;

      ok = 0;
      if (!check_signal(name, data, why) || !can_use(1, why))
        return;
      item = ctrl_item(name, data, why);
      if (item == null)
        return;
      ahead = adapter.tx_pending_count() + endpoint.tx_pending_count() + (endpoint.tx_is_busy() ? 1 : 0);
      target = endpoint.tx_frames + ahead + 1;
      send(-1, item);
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
      `uvm_info_context("ETH_SHM_CTRL", $sformatf("%s: sent signal '%s' (%0d data bytes)", subject(), name, data.len()),
                        UVM_MEDIUM, reporter())
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
        `uvm_info_context("ETH_SHM_CTRL", $sformatf("%s: signal '%s' taken after %0d ms (%0d data bytes)", subject(), name,
                          now_ms - start_ms, data.len()), UVM_LOW, reporter())
      else
        `uvm_info_context("ETH_SHM_CTRL", {subject(), ": wait for '", name, "' failed: ", why}, UVM_LOW, reporter())
    endtask

    // 校验控制帧本体（EtherType 与魔数、FCS、长度）后按名字缓存；不合格报 ETH_SHM_CTRL（UVM_ERROR）并丢弃，缓存满
    // （shm_queue_depth 个未取走的信号）即 fail closed。保留名 "#links" 交给链路名集合核对。
    protected function void take_ctrl(shm_frame frame, int offset);
      int n = frame.payload.size() - offset - 4;
      int unsigned name_len;
      int unsigned data_len;
      byte unsigned body[];
      bit [31:0] fcs;
      string name;
      string data;

      if (n < int'(CTRL_HEAD) + 3) begin
        drop_ctrl(frame, $sformatf("%0d-byte body is too short", (n < 0) ? 0 : n));
        return;
      end
      body = new[n];
      foreach (body[i]) body[i] = frame.payload[offset + i];
      for (int b = 0; b < 4; b++) fcs[b*8 +: 8] = frame.payload[offset + n + b];
      if ({body[12], body[13]} != CTRL_TYPE) begin
        drop_ctrl(frame, $sformatf("EtherType 0x%02h%02h is not 0x88b5", body[12], body[13]));
        return;
      end
      for (int i = 0; i < 8; i++)
        if (body[14 + i] != CTRL_MAGIC[(7 - i)*8 +: 8]) begin
          drop_ctrl(frame, "magic is not ETHSHMC1");
          return;
        end
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
      if (name == LINKS_SIGNAL) begin
        check_peer_links(data);
        return;
      end
      if (ctrl_buffered >= shm_queue_depth) begin
        shm_runtime::fail($sformatf("%s: control signal '%s' lost: %0d signals are unclaimed (shm_queue_depth=%0d)",
                                    subject(), name, ctrl_buffered, shm_queue_depth));
        return;
      end
      ctrl_box[name].push_back(data);
      ctrl_buffered++;
      ctrl_received++;
      `uvm_info_context("ETH_SHM_CTRL", $sformatf("%s: received signal '%s' (%0d data bytes)", subject(), name, data_len),
                        UVM_MEDIUM, reporter())
    endfunction

    protected function void drop_ctrl(shm_frame frame, string why);
      ctrl_dropped++;
      `uvm_error_context("ETH_SHM_CTRL", $sformatf("%s: control frame from port %0d (%0d bytes) dropped: %s", subject(),
                                                    frame.src_port, frame.payload.size(), why), reporter())
    endfunction

    // 尚未被 wait 取走的信号名（按名字排序，同名多个时重复列出），供 report 打印。
    function string unclaimed();
      string text = "";
      foreach (ctrl_box[name])
        foreach (ctrl_box[name][i])
          text = {text, (text == "") ? "" : ",", name};
      return text;
    endfunction

    // shm_link_check：就绪后（时间 0，排在任何数据帧之前）把本端链路名集合作为保留信号 "#links" 交给 adapter，不等待交付。
    protected function void send_link_list();
      eth_seg_seq_item item;
      string names = link_names();
      string why;
      if (names.len() > CTRL_DATA_MAX) begin
        fail_closed("ETH_SHM_LINKS", $sformatf("%s: shm_link_check: the link name list has %0d characters, above %0d",
                                                subject(), names.len(), CTRL_DATA_MAX));
        return;
      end
      item = ctrl_item(LINKS_SIGNAL, names, why);
      if (item == null) begin
        fail_closed("ETH_SHM_LINKS", {subject(), ": shm_link_check: ", why});
        return;
      end
      send(-1, item);
      `uvm_info_context("ETH_SHM_LINKS", $sformatf("%s: sent the SHM link set %s to the peer", subject(), names),
                        UVM_MEDIUM, reporter())
    endfunction

    // 对端的链路名集合（无论本端是否打开 shm_link_check 都核对）：不同即 fail closed，并列出两边独有的名字。先收到
    // 对端集合的一端报告，SimFlow 随即结束整组节点，另一端可能来不及报告。
    protected function void check_peer_links(string peer);
      string mine = link_names();
      string only_mine = "";
      string only_peer = "";
      bit peer_has[string];
      bit mine_has[string];
      int start = 0;
      peer_links_seen = 1;
      if (peer == mine) begin
        `uvm_info_context("ETH_SHM_LINKS", $sformatf("%s: SHM link set matches the peer (%s)", subject(), mine), UVM_LOW,
                          reporter())
        return;
      end
      for (int i = 0; i <= peer.len(); i++)
        if (i == peer.len() || peer[i] == ",") begin
          if (i > start) peer_has[peer.substr(start, i - 1)] = 1;
          start = i + 1;
        end
      foreach (links[i]) begin
        mine_has[links[i].link_name] = 1;
        if (!peer_has.exists(links[i].link_name))
          only_mine = {only_mine, (only_mine == "") ? "" : ",", links[i].link_name};
      end
      foreach (peer_has[name])
        if (!mine_has.exists(name)) only_peer = {only_peer, (only_peer == "") ? "" : ",", name};
      fail_closed("ETH_SHM_LINKS", $sformatf({"SHM link set differs from the peer: local %s, peer %s (only local: %s; only ",
                                              "peer: %s); both nodes need the same shm=1 link names"}, mine, peer,
                                             (only_mine == "") ? "none" : only_mine,
                                             (only_peer == "") ? "none" : only_peer));
    endfunction

    // 打开 shm_link_check 而直到结束都没收到对端的链路名集合：对端多半没打开它。
    function void check_phase(uvm_phase phase);
      super.check_phase(phase);
      if (endpoint != null && ready && shm_link_check && shm_cfg.direction != SHM_TX_ONLY && !peer_links_seen)
        `uvm_error_context("ETH_SHM_LINKS", {subject(), ": shm_link_check=1 but the peer never sent its SHM link set ",
                                             "(set shm_link_check=1 on both nodes)"}, reporter())
    endfunction

    // 多条链路时控制通道的统计单独一行（只有一条链路时并入该链路的 ETH_SHM 行，与多链路之前相同）。
    function void report_phase(uvm_phase phase);
      string left;
      super.report_phase(phase);
      if (endpoint == null || links.size() < 2) return;
      left = unclaimed();
      `uvm_info("ETH_SHM", $sformatf("links=%s ctrl_sent=%0d ctrl_received=%0d ctrl_dropped=%0d ctrl_unclaimed=%s",
                                     link_names(), ctrl_sent, ctrl_received, ctrl_dropped, (left == "") ? "none" : left),
                UVM_LOW)
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
      if (inst == null)
        why = "no SHM link in this simulation (a MAC active agent needs +<agent>.shm=1 inside an SHM cosim)";
      else
        inst.signal(value.exists("name") ? value["name"] : "", value.exists("data") ? value["data"] : "", ok, why);
      handle.status = ok ? 0 : 1;
      handle.result_out = ok ? {"OK: eth_shm_signal: ", value["name"]} : {"ERROR: eth_shm_signal: ", why};
    endtask

    // Tcl eth_shm_wait name=<名字> [timeout_ms=<毫秒>]：成功 "OK: eth_shm_wait: <数据>"，超时等失败 status=1 与 "ERROR: ..."；
    // timeout_ms 缺省取 <agent>.shm_wait_timeout_ms（各 shm=1 agent 相同）。
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
      if (inst == null)
        why = "no SHM link in this simulation (a MAC active agent needs +<agent>.shm=1 inside an SHM cosim)";
      else if (aip_cmd::parse_uint_arg(value.exists("timeout_ms") ? value["timeout_ms"] : "", 32'hffff_ffff,
                                       inst.shm_wait_timeout_ms, timeout_ms, why, "timeout_ms"))
        inst.wait_signal(value.exists("name") ? value["name"] : "", timeout_ms, ok, data, why);
      handle.status = ok ? 0 : 1;
      handle.result_out = ok ? {"OK: eth_shm_wait: ", data} : {"ERROR: eth_shm_wait: ", why};
    endtask
  endclass

  // agent 的子组件，build 时取父 agent 的 cfg/sequencer 并登记到 hub，connect 时自行接 TX monitor、rx_driver.sent_ap 与
  // hub reset_ap，本链路的解码队列登记为 agent sequencer 的 SHM source。队列全部有界，满即 fail closed。
  class eth_seg_shm_link #(int RATE = 100) extends eth_seg_shm_link_base;
    `uvm_component_param_utils(eth_seg_shm_link#(RATE))

    eth_seg_agent#(RATE) agent;
    eth_seg_config#(RATE) cfg;
    uvm_analysis_imp_shm_link_tx#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) tx_export;
    uvm_analysis_imp_shm_link_sent#(eth_seg_seq_item, eth_seg_shm_link#(RATE)) sent_export;
    uvm_analysis_imp_shm_link_reset#(eth_seg_reset_notice_t, eth_seg_shm_link#(RATE)) reset_export;

    protected int unsigned tx_index;     // TX monitor 帧序号，从 0 计
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
      rx_include_fcs = cfg.include_fcs;
      shm_link = agent.get_name();
      `aip_string(param_path, shm_link, shm_link)
      `aip_uint(param_path, int unsigned, shm_queue_depth, shm_queue_depth)
      `aip_uint(param_path, int unsigned, shm_max_frame, shm_max_frame)
      `aip_uint(param_path, int unsigned, shm_tx_timeout_ms, shm_tx_timeout_ms)
      `aip_uint(param_path, int unsigned, shm_idle_sleep_us, shm_idle_sleep_us)
      `aip_uint(param_path, int unsigned, shm_wait_poll_ns, shm_wait_poll_ns)
      `aip_uint(param_path, int unsigned, shm_wait_sleep_us, shm_wait_sleep_us)
      `aip_uint(param_path, int unsigned, shm_wait_timeout_ms, shm_wait_timeout_ms)
      `aip_int(param_path, bit, shm_link_check, shm_link_check)
      if (shm_wait_poll_ns == 0 || shm_wait_sleep_us > shm_endpoint_config::MAX_DPI_SLEEP_US || shm_wait_timeout_ms == 0) begin
        `uvm_fatal("ETH_SHM_CFG", $sformatf({"%s: invalid control-signal waits shm_wait_poll_ns=%0d (>0) ",
                                             "shm_wait_sleep_us=%0d (<1000000) shm_wait_timeout_ms=%0d (>0)"},
                                            param_path, shm_wait_poll_ns, shm_wait_sleep_us, shm_wait_timeout_ms))
        return;
      end
      if (!eth_seg_shm_fmt::link_name_ok(shm_link)) begin
        `uvm_fatal("ETH_SHM_CFG", $sformatf({"%s: SHM link name '%s' needs 1..%0d letters, digits or _ . - ",
                                             "(set +%s.shm_link=<name>)"}, param_path, shm_link, ETH_SHM_NAME_MAX,
                                            param_path))
        return;
      end
      link_name = shm_link;
      if (!shm_runtime::initialize()) return;
      if (!shm_runtime::is_enabled()) begin
        `uvm_fatal("ETH_SHM_CFG", {param_path, ".shm=1 requires +SHM_ENABLE=1 and the SHM transport plusargs ",
                                   "(SimFlow def_shm_cosim supplies them)"})
        return;
      end
      hub = eth_seg_shm_hub::attach(this);
      if (hub == null) return;
      endpoint = hub.endpoint;
      if (hub.shm_cfg.direction != SHM_TX_ONLY)
        source = new({link_name, "_source"}, shm_queue_depth);
    endfunction

    // 本链路的解码队列登记为 agent sequencer 的 SHM source（owner sequence 按 sequencer 找到它）。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (endpoint == null) return;
      agent.tx_monitor.item_collected_port.connect(tx_export);
      agent.rx_driver.sent_ap.connect(sent_export);
      agent.monitor_hub.reset_ap.connect(reset_export);
      if (source != null) shm_item_source_registry::bind_source(agent.sequencer, source);
    endfunction

    task run_phase(uvm_phase phase);
      bit ok;
      if (endpoint == null) return;
      hub.wait_ready(ok);
      if (!ok || source == null) return;
      owner = eth_seg_shm_owner_seq::type_id::create("shm_owner_seq");
      owner.link = this;
      owner.start(agent.sequencer);
    endtask

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

    // TX monitor 在 EOP 调用：TX 复位中、格式错误、过短或本节点无目的端口的帧不发送并计数；连同链路头超过 shm_max_frame
    // 的帧 fail closed；其余帧带上链路名交 hub（满即 fatal）。loopback 每帧重读，运行中打开即报 ETH_SHM_LOOPBACK。
    function void write_shm_link_tx(eth_seg_seq_item tx);
      int unsigned index;
      int body_len;
      int unsigned head;
      if (tx == null || endpoint == null) return;
      index = tx_index++;
      if (cfg.sample_loopback(param_path) && !loopback_reported) begin
        loopback_reported = 1;
        `uvm_error("ETH_SHM_LOOPBACK", {param_path, ": loopback and shm are mutually exclusive; frames still go to SHM"})
      end
      if (!hub.ready) begin
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
      if (hub.shm_cfg.direction == SHM_RX_ONLY) begin
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
      head = eth_seg_shm_fmt::data_head_len(link_name);
      if (head + body_len + 4 > shm_max_frame) begin
        shm_runtime::fail($sformatf({"%s: TX frame #%0d is %0d bytes with FCS; with the %0d-byte link header it is above ",
                                     "shm_max_frame=%0d; raise shm_max_frame on every shm=1 agent (+%s.shm_max_frame) and ",
                                     "the fabric slot_size"}, param_path, index, body_len + 4, head, shm_max_frame,
                                    param_path));
        return;
      end
      report_tx_error(tx, index, tx.inject_error ? "sent to SHM with the FCS inverted" : "sent to SHM with its FCS unchanged");
      hub.send(hub_index, tx);
      sent_frames++;
    endfunction

    // 按 shm_work 模板在复位断言沿清队，按方向拆开：TX 断言从共用 TX 队列移除本链路的帧（endpoint 已收下的帧视为已上
    // 线路），RX 断言清本链路的解码队列并让 epoch 加一（owner 逐帧判旧），rx_driver 丢弃的在途帧一并计入 flushed。
    // 仿真开始时按复位处理，首个通知不算断言沿，避免清掉对端早于本端复位释放到达的帧。
    function void write_shm_link_reset(eth_seg_reset_notice_t notice);
      bit was_in_reset = in_reset[notice.direction];
      in_reset[notice.direction] = notice.asserted;
      if (!notice.asserted || was_in_reset || hub == null || hub.adapter == null) return;
      if (notice.direction == ETH_SEG_TX) begin
        flushed_frames += hub.flush_tx(hub_index);
        return;
      end
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

    // 只有一条链路时控制信号的计数并入本行（与多链路之前相同）；多条链路时每条链路一行 link=<名字>，
    // 控制通道另由 hub 打印一行。ctrl_unclaimed 列出结束时仍未被 wait 取走的信号名。
    function void report_phase(uvm_phase phase);
      string left;
      super.report_phase(phase);
      if (endpoint == null) return;
      if (hub.links.size() == 1) begin
        left = hub.unclaimed();
        `uvm_info("ETH_SHM", $sformatf({"%s: sent=%0d received=%0d driven=%0d flushed=%0d dropped=%0d tx_errors=%0d pending=%0d ",
                                        "ctrl_sent=%0d ctrl_received=%0d ctrl_dropped=%0d ctrl_unclaimed=%s"},
                  param_path, sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames, tx_errors,
                  pending(), hub.ctrl_sent, hub.ctrl_received, hub.ctrl_dropped, (left == "") ? "none" : left), UVM_LOW)
      end
      else
        `uvm_info("ETH_SHM", $sformatf("%s: link=%s sent=%0d received=%0d driven=%0d flushed=%0d dropped=%0d tx_errors=%0d pending=%0d",
                  param_path, link_name, sent_frames, received_frames, driven_frames, flushed_frames, dropped_frames,
                  tx_errors, pending()), UVM_LOW)
    endfunction
  endclass

  // agent 只认名字（基础包不依赖本包），三档速率各登记一个。
  typedef uvm_component_registry #(eth_seg_shm_link#(100), "eth_seg_shm_link_100") eth_seg_shm_link_100_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(200), "eth_seg_shm_link_200") eth_seg_shm_link_200_registry;
  typedef uvm_component_registry #(eth_seg_shm_link#(400), "eth_seg_shm_link_400") eth_seg_shm_link_400_registry;

  // 两个仿真之间的握手命令（目标是本进程的 hub，节点级），说明见 eth_seg_shm_hub::signal_cmd/wait_cmd。
  `aip_cmd_task(eth_shm_signal, eth_seg_shm_hub::signal_cmd)
  `aip_cmd_task(eth_shm_wait, eth_seg_shm_hub::wait_cmd)
endpackage
`endif
