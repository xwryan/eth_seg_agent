// 公共网络报文 sequence（在 eth_net_packet_pkg 内编译）：把 net_packet 报文转换为字节事务发送，并提供整包采样接口。
// 不 include net_packet 单文件，避免同名 packet 出现在不同 package；RM/SCB 采样用 set_sequencer，不启动 body。
class eth_base_seq extends uvm_sequence#(eth_seg_seq_item);
  `uvm_object_utils(eth_base_seq)

  // 非空 pkt 按原字节重放 count 次；为空时每轮调用 create_packet 新建（只用局部对象，不回写 pkt）。
  net_packet_pkg::packet pkt;
  int count = 1;
  protected bit last_send_ok;

  function new(string name = "eth_base_seq");
    super.new(name);
  endfunction

  // 采样允许 passive sqr，发送拒绝没有 driver 的 sqr。
  protected function eth_seg_sequencer require_sqr(bit sending = 0);
    eth_seg_sequencer handle;
    if (!$cast(handle, get_sequencer()) || handle == null) begin
      `uvm_fatal("ETH_NET_SQR", "an Ethernet sequencer must be associated before use")
      return null;
    end
    if (sending && !handle.can_send) begin
      `uvm_fatal("ETH_NET_PASSIVE", "this Ethernet sequencer has no sending driver")
      return null;
    end
    return handle;
  endfunction

  // portid 只在当前 agent/方向内区分消费者，与 IP 编号无关。
  function void subscribe(eth_seg_dir_e dir, int unsigned portid = 0, int unsigned depth = 1024);
    eth_seg_sequencer handle = require_sqr();
    if (handle != null) handle.subscribe(dir, portid, depth);
  endfunction

  // timeout=0 无限等待；超时/取消返回 null（复位清缓存但继续等待），调用者必须检查返回句柄。
  task mon_xaction(output eth_seg_seq_item tr, input eth_seg_dir_e dir,
                   input int unsigned portid = 0, input time timeout = 0);
    eth_seg_sequencer handle = require_sqr();
    tr = null;
    if (handle != null) handle.mon_xaction(tr, dir, portid, timeout);
  endtask

  // 发送命令结束不会自动取消持久订阅。
  function void unsubscribe(eth_seg_dir_e dir, int unsigned portid = 0);
    eth_seg_sequencer handle = require_sqr();
    if (handle != null) handle.unsubscribe(dir, portid);
  endfunction

  // 默认每包新建 256B IPv4/UDP，子类覆写以读取参数；修改协议头后需重新 do_pack，返回的字节才反映新字段。
  virtual function net_packet_pkg::packet create_packet(int unsigned packet_index);
    net_packet_pkg::packet generated = new();
    generated.build_from_template(net_packet_pkg::ETH_IPV4_UDP);
    generated.pkt_len = 256;
    generated.payload_mode = net_packet_pkg::PAYLOAD_FIXED;
    generated.payload_fixed_val = 8'ha5;
    generated.do_pack();
    return generated;
  endfunction

  // 每包成功入队后的可选钩子，不表示物理完成。
  virtual function void packet_queued(int unsigned packet_index);
  endfunction

  // raw_data[0] 对应目的 MAC 首字节；非空 raw_data 即权威输入，不重新打包、不修复校验和、不补短帧、不剥 ICRC。
  // raw_data 为空时只允许自动打包 Ethernet 协议栈；空句柄/空栈/非 Ethernet/小于 14B 立即 fatal 并返回 null。
  virtual function eth_seg_seq_item packet_to_item(input net_packet_pkg::packet net_pkt);
    eth_seg_seq_item item;

    if (net_pkt == null) begin
      `uvm_fatal("ETH_NET_NULL", "packet must not be null")
      return null;
    end

    if (net_pkt.raw_data.size() == 0) begin
      if (net_pkt.layer_stack.size() == 0) begin
        `uvm_fatal("ETH_NET_EMPTY", "packet has neither packed bytes nor protocol layers")
        return null;
      end
      foreach (net_pkt.layer_stack[i]) begin
        if (net_pkt.layer_stack[i] == null) begin
          `uvm_fatal("ETH_NET_LAYER", "packet contains a null protocol layer")
          return null;
        end
      end
      if (net_pkt.layer_stack[0].proto_type != net_packet_pkg::PROTO_ETHERNET) begin
        `uvm_fatal("ETH_NET_LAYER", "unpacked packet must start with Ethernet")
        return null;
      end
      net_pkt.do_pack();
    end

    if (net_pkt.raw_data.size() < 14) begin
      `uvm_fatal("ETH_NET_LENGTH", "Ethernet packet must contain at least 14 bytes")
      return null;
    end

    item = eth_seg_seq_item::type_id::create("net_frame");
    item.frame_bytes = new[net_pkt.raw_data.size()];
    foreach (item.frame_bytes[i]) item.frame_bytes[i] = net_pkt.raw_data[i];
    // net_packet 输出不含 Ethernet FCS（RoCEv2 ICRC 属于报文内容）；前导/FCS 由 cfg/codec 添加，不按末尾 4 字节猜格式。
    item.fcs_present = 0;
    return item;
  endfunction

  // 方向由 agent 的 driver 决定；finish_item 只表示 driver 已入队，结束 test 前须等待 monitor/scoreboard。
  virtual task send_packet(input net_packet_pkg::packet net_pkt);
    eth_seg_seq_item item;

    last_send_ok = 0;
    if (require_sqr(1) == null) return;
    item = packet_to_item(net_pkt);
    if (item == null) return;
    start_item(item);
    finish_item(item);
    last_send_ok = 1;
  endtask

  // 唯一的 count 循环，生成或转换失败即停止；Tcl 命令返回不代表 count 个包已全部上线，调用者需持有 objection 到排空。
  virtual task body();
    if (require_sqr(1) == null) return;
    if (count <= 0) begin
      `uvm_fatal("ETH_NET_COUNT", "count must be positive")
      return;
    end
    for (int n = 0; n < count; n++) begin
      net_packet_pkg::packet current_packet;
      current_packet = (pkt != null) ? pkt : create_packet(n);
      if (current_packet == null) begin
        `uvm_fatal("ETH_NET_NULL", "packet generator returned null")
        return;
      end
      send_packet(current_packet);
      if (!last_send_ok) return;
      packet_queued(n);
    end
  endtask
endclass
