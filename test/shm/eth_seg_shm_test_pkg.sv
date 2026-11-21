// SHM 双节点联仿测试。两个节点由 SimFlow 的 BIDIR cosim 背靠背相连，按共享 seed 确定性生成帧，各自逐字节、按序核对
// 收到的对端帧，并经 AIP end_test 等待 shm_transport（endpoint 计数与排空）和本地比对两个检查器。
// eth_seg_shm_test：一条 100G link，CLIENT lb0_client 代替 DUT 发 TX，MAC lb0_mac 由 +lb0_mac.shm=1 接入 SHM fabric。
// 参数 +shm_eth.<名>（SimFlow 节点 params）：self/peer 流编号、tx_frames/rx_frames、seed；tx_errors/rx_errors 表示
// 本端/对端第 3 帧坏 FCS、第 7 帧 EOP error；drop_index/corrupt_index 是发送端故障注入，只用于证明丢帧或改帧会失败；
// ctrl_tx/ctrl_rx 是节点 Tcl（eth_shm_handshake.tcl）经控制通道发出/收下的信号数，计入 endpoint 收发期望并逐项核对。
// eth_seg_shm_mlink_test：同一仿真里多条链路同时收发（端口见 tb_shm，参数见该类）。
package eth_seg_shm_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  `include "eth_seg_agent_import.svh"
  import shm_uvm_pkg::*;
  import shm_aip_pkg::*;
  `include "eth_seg_agent_shm_import.svh"
  import eth_seg_loopback_test_pkg::*;
  `include "uvm_macros.svh"

  typedef class eth_seg_shm_test;
  typedef class eth_seg_shm_mlink_test;

  // 帧的长度与内容只由 seed、流编号与帧号决定，两个节点各自生成同一份；前 4 字节写入流编号与帧号便于定位。
  class shm_stream;
    static function int unsigned next(int unsigned x);
      x ^= x << 13;
      x ^= x >> 17;
      x ^= x << 5;
      return x;
    endfunction

    static function void frame(int unsigned seed, int unsigned stream, int unsigned k, ref byte unsigned bytes[]);
      int unsigned s = next(seed ^ (stream * 32'h9e3779b9) ^ (k * 32'h85ebca6b) ^ 32'h5a5a_0001);
      if (s == 0) s = 32'h1234_5678;
      bytes = new[60 + s % 1441];
      foreach (bytes[i]) begin
        s = next(s);
        bytes[i] = s[7:0];
      end
      bytes[0] = 8'h02;
      bytes[1] = byte'(stream);
      bytes[2] = byte'(k);
      bytes[3] = byte'(k >> 8);
    endfunction

    // 多链路：流由发送节点与链路名决定（不是端口序号），收端按自己链路的名字推算期望，按名字分发错了即比对失败。
    static function void link_frame(int unsigned seed, int unsigned node, string link, int unsigned k,
                                    ref byte unsigned bytes[]);
      byte unsigned name[];
      name = new[link.len()];
      foreach (name[i]) name[i] = link[i];
      frame(seed, node ^ (eth_seg_codec::crc32(name) << 1), k, bytes);
    endfunction

    static function bit bad_fcs(int unsigned k);
      return k == 3;
    endfunction

    static function bit eop_error(int unsigned k);
      return k == 7;
    endfunction

    // 对端第 k 帧在本端 MAC RX monitor 上的期望：字节原样，本端 include_fcs 时带 FCS（坏帧按发送端的改法），
    // rx_fcs_error 只在对端标了错的两帧为 1。
    static function eth_seg_seq_item expected(byte unsigned body[], int unsigned k, bit include_fcs, bit errors);
      eth_seg_seq_item exp = new("expected_rx");
      bit [31:0] crc;
      exp.fcs_present = include_fcs;
      exp.rx_fcs_error = errors && (bad_fcs(k) || eop_error(k));
      if (!include_fcs) exp.frame_bytes = body;
      else begin
        crc = eth_seg_codec::crc32(body);
        if (errors && eop_error(k)) crc = ~crc;
        else if (errors && bad_fcs(k)) crc[31:24] ^= 8'h01;
        exp.frame_bytes = new[body.size() + 4];
        foreach (body[i]) exp.frame_bytes[i] = body[i];
        for (int b = 0; b < 4; b++) exp.frame_bytes[body.size()+b] = crc[b*8 +: 8];
      end
      return exp;
    endfunction
  endclass

  // ETH_SHM_TX_ERROR 是 tx_errors 节点的预期诊断：保存正文并降为 UVM_INFO。
  class shm_tx_error_catcher extends uvm_report_catcher;
    string msgs[$];

    function new(string name = "shm_tx_error_catcher");
      super.new(name);
    endfunction

    virtual function action_e catch();
      if (get_id() != "ETH_SHM_TX_ERROR") return THROW;
      msgs.push_back(get_message());
      if (get_severity() == UVM_ERROR) set_severity(UVM_INFO);
      return THROW;
    endfunction
  endclass

  // end_test 轮询（零时间）：逐帧比对新到的对端帧，收齐、全部一致且链路排空才完成。
  class shm_rx_checker extends aip_end_checker;
    eth_seg_shm_test test;

    function new(eth_seg_shm_test test);
      this.test = test;
    endfunction

    virtual function bit is_done();
      return test.rx_done();
    endfunction

    virtual function bit has_failed();
      return test.rx_failed();
    endfunction

    virtual function string status_detail();
      return test.rx_detail();
    endfunction
  endclass

  class eth_seg_shm_test extends uvm_test;
    `uvm_component_utils(eth_seg_shm_test)

    lb_case#(100) lb0;
    eth_seg_shm_link#(100) link;
    shm_tx_error_catcher tx_error_catcher;
    shm_transport_checker transport;
    shm_rx_checker rx_checker;
    int unsigned self = 0, peer = 1, tx_frames = 0, rx_frames = 0, seed = 1, ctrl_tx = 0, ctrl_rx = 0;
    bit tx_errors = 0, rx_errors = 0;
    int drop_index = -1, corrupt_index = -1;
    int unsigned expected_tx, checked, mismatches;

    function new(string name = "eth_seg_shm_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      `aip_uint("shm_eth", int unsigned, self, self)
      `aip_uint("shm_eth", int unsigned, peer, peer)
      `aip_uint("shm_eth", int unsigned, tx_frames, tx_frames)
      `aip_uint("shm_eth", int unsigned, rx_frames, rx_frames)
      `aip_uint("shm_eth", int unsigned, seed, seed)
      `aip_int("shm_eth", bit, tx_errors, tx_errors)
      `aip_int("shm_eth", bit, rx_errors, rx_errors)
      `aip_int("shm_eth", int, drop_index, drop_index)
      `aip_int("shm_eth", int, corrupt_index, corrupt_index)
      `aip_uint("shm_eth", int unsigned, ctrl_tx, ctrl_tx)
      `aip_uint("shm_eth", int unsigned, ctrl_rx, ctrl_rx)
      lb0 = new("lb0", this);
      tx_error_catcher = new();
      uvm_report_cb::add(null, tx_error_catcher);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (lb0.mac.shm_link == null || !$cast(link, lb0.mac.shm_link) || link.endpoint == null)
        `uvm_fatal("SHM_TEST", "lb0_mac needs +lb0_mac.shm=1 inside an SHM cosim")
      if (tx_errors && !lb0.client.cfg.include_fcs)
        `uvm_fatal("SHM_TEST", "tx_errors needs +lb0_client.include_fcs=1 for the bad-FCS frame")
      expected_tx = tx_frames - ((drop_index >= 0 && drop_index < tx_frames) ? 1 : 0);
      // endpoint 计数含控制帧：期望为数据帧加本节点 Tcl 发出/收下的控制信号。
      transport = new(link.endpoint, null, expected_tx + ctrl_tx, rx_frames + ctrl_rx);
      rx_checker = new(this);
      aip_tcl_bridge::register_end_checker("shm_transport", transport);
      aip_tcl_bridge::register_end_checker("eth_shm_rx", rx_checker);
    endfunction

    function eth_seg_seq_item expected_rx(int unsigned k);
      byte unsigned body[];
      shm_stream::frame(seed, peer, k, body);
      return shm_stream::expected(body, k, lb0.mac.cfg.include_fcs, rx_errors);
    endfunction

    // 比对用 lb_case::check_frame（报告具体差异），以 UVM_ERROR 计数增量判定该帧是否一致。
    function void check_new_frames();
      uvm_report_server server = uvm_report_server::get_server();
      while (checked < lb0.rx_seen.items.size()) begin
        int errors = server.get_severity_count(UVM_ERROR);
        if (checked >= rx_frames)
          `uvm_error("SHM_TEST_EXTRA", $sformatf("unexpected peer frame #%0d (expected %0d)", checked, rx_frames))
        else
          lb0.check_frame(expected_rx(checked), lb0.rx_seen.items[checked], $sformatf("peer frame #%0d", checked));
        if (server.get_severity_count(UVM_ERROR) != errors) mismatches++;
        checked++;
      end
    endfunction

    function bit rx_done();
      check_new_frames();
      return mismatches == 0 && checked == rx_frames && lb0.tx_seen.items.size() == expected_tx &&
             link.sent_frames == expected_tx && link.is_idle() && lb0.client.tx_driver.is_idle() &&
             lb0.client.rx_monitor.is_idle();
    endfunction

    function bit rx_failed();
      check_new_frames();
      return mismatches != 0;
    endfunction

    function string rx_detail();
      return $sformatf("peer frames %0d/%0d mismatches=%0d sent %0d/%0d link_pending=%0d",
                       checked, rx_frames, mismatches, link.sent_frames, expected_tx, link.pending());
    endfunction

    task run_phase(uvm_phase phase);
      eth_seg_seq_item frames[$];
      phase.raise_objection(this);
      for (int unsigned k = 0; k < tx_frames; k++) begin
        eth_seg_seq_item item;
        if (k == drop_index) continue;
        item = new($sformatf("shm_tx_%0d", k));
        shm_stream::frame(seed, self, k, item.frame_bytes);
        if (k == corrupt_index) item.frame_bytes[20] ^= 8'hff;
        item.inject_fcs_error = tx_errors && shm_stream::bad_fcs(k);
        item.inject_error = tx_errors && shm_stream::eop_error(k);
        frames.push_back(item);
      end
      // 链路在时间 0 已等到 fabric 就绪；复位释放后 CLIENT 立即连续发帧，同时由 Tcl end_test 判定完成。
      lb0.release_reset();
      fork
        lb0.send(lb0.client.sequencer, frames);
      join_none
      aip_tcl_bridge::run_loop();
      final_check();
      phase.drop_objection(this);
    endtask

    // end_test 失败只打 aip [ERROR]，这里把两个检查器的结论转成 UVM_ERROR，再核对计数与诊断。
    function void final_check();
      int unsigned expected_errors = tx_errors ? 2 : 0;
      eth_seg_shm_hub hub = link.hub;
      check_new_frames();
      if (transport.has_failed() || !transport.is_done())
        `uvm_error("SHM_TEST_TRANSPORT", {"shm_transport not complete: ", transport.status_detail()})
      if (rx_failed() || !rx_done())
        `uvm_error("SHM_TEST_RX", {"eth_shm_rx not complete: ", rx_detail()})
      if (checked != rx_frames)
        `uvm_error("SHM_TEST_COUNT", $sformatf("received %0d peer frames, expected %0d", checked, rx_frames))
      lb0.check_dut_view();
      if (link.sent_frames != expected_tx || link.received_frames != rx_frames || link.driven_frames != rx_frames ||
          link.flushed_frames != 0 || link.dropped_frames != 0 || link.tx_errors != expected_errors)
        `uvm_error("SHM_TEST_LINK", $sformatf("link sent=%0d/%0d received=%0d driven=%0d/%0d flushed=%0d dropped=%0d tx_errors=%0d/%0d",
                   link.sent_frames, expected_tx, link.received_frames, link.driven_frames, rx_frames,
                   link.flushed_frames, link.dropped_frames, link.tx_errors, expected_errors))
      if (hub.ctrl_sent != ctrl_tx || hub.ctrl_received != ctrl_rx || hub.ctrl_dropped != 0 || hub.unclaimed() != "")
        `uvm_error("SHM_TEST_CTRL", $sformatf("control signals sent=%0d/%0d received=%0d/%0d dropped=%0d unclaimed='%s'",
                   hub.ctrl_sent, ctrl_tx, hub.ctrl_received, ctrl_rx, hub.ctrl_dropped, hub.unclaimed()))
      if (tx_error_catcher.msgs.size() != expected_errors)
        `uvm_error("SHM_TEST_TX_ERROR", $sformatf("%0d ETH_SHM_TX_ERROR reports, expected %0d",
                   tx_error_catcher.msgs.size(), expected_errors))
      else if (tx_errors &&
               (aip_str::str_find(tx_error_catcher.msgs[0], "TX frame #3 ") < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[0], "bad FCS") < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[1], "TX frame #7 ") < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[1], "EOP error") < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[1], "FCS inverted") < 0))
        `uvm_error("SHM_TEST_TX_ERROR", {"unexpected ETH_SHM_TX_ERROR text: ", tx_error_catcher.msgs[0], " | ",
                                         tx_error_catcher.msgs[1]})
      `uvm_info("ETH_SHM_COSIM_TEST_COMPLETE",
                $sformatf({"node=%0d sent=%0d received=%0d mismatches=%0d tx_errors=%0d ctrl_sent=%0d ctrl_received=%0d ",
                           "endpoint tx=%0d rx=%0d full_retry=%0d paused_retry=%0d"},
                          self, link.sent_frames, checked, mismatches, link.tx_errors, hub.ctrl_sent, hub.ctrl_received,
                          link.endpoint.tx_frames, link.endpoint.rx_frames, link.endpoint.tx_full_retry,
                          link.endpoint.tx_paused_retry), UVM_NONE)
    endfunction

    // SimFlow 的日志检查以此为结束标记，只检查标记之前的内容（之后是 UVM 汇总）。
    function void report_phase(uvm_phase phase);
      uvm_report_server server = uvm_report_server::get_server();
      super.report_phase(phase);
      if (server.get_severity_count(UVM_ERROR) == 0 && server.get_severity_count(UVM_FATAL) == 0)
        $display("*** TEST PASSED ***");
      else
        $display("*** TEST FAILED ***");
    endfunction
  endclass

  // 多链路测试的一个端口（与速率无关的接口）：lb_case 名即端口名，bind 的 agent 为 <端口>_client（代替 DUT 发 TX）与
  // <端口>_mac（shm=1 接入 SHM）。shm_port#(RATE) 包装 lb_case#(RATE)，不同速率的端口可放在同一用例。
  virtual class shm_port_base;
    string name;
    eth_seg_shm_link_base link;
    eth_seg_seq_item frames[$];   // 本端经 CLIENT 发出的帧
    int unsigned expected_tx;     // 本端应发出（MAC TX monitor 采到、链路交给 SHM）的帧数
    int unsigned checked, mismatches;

    pure virtual function void build(uvm_component parent);
    pure virtual function string mac_path();
    pure virtual function bit find_link();
    pure virtual task release_reset();
    pure virtual task send();
    pure virtual function int unsigned tx_seen();
    pure virtual function int unsigned rx_seen();
    pure virtual function eth_seg_seq_item rx_item(int unsigned i);
    pure virtual function bit mac_include_fcs();
    pure virtual function bit client_include_fcs();
    pure virtual function void check_frame(eth_seg_seq_item exp, eth_seg_seq_item got, string what);
    pure virtual function bit client_idle();
    pure virtual function void check_dut_view();
  endclass

  class shm_port #(int RATE = 100) extends shm_port_base;
    lb_case#(RATE) lb;

    function new(string name);
      this.name = name;
    endfunction

    virtual function void build(uvm_component parent);
      lb = new(name, parent);
    endfunction

    virtual function string mac_path();
      return lb.mac.get_full_name();
    endfunction

    virtual function bit find_link();
      return lb.mac.shm_link != null && $cast(link, lb.mac.shm_link) && link.endpoint != null;
    endfunction

    virtual task release_reset();
      lb.release_reset();
    endtask

    virtual task send();
      lb.send(lb.client.sequencer, frames);
    endtask

    virtual function int unsigned tx_seen();
      return lb.tx_seen.items.size();
    endfunction

    virtual function int unsigned rx_seen();
      return lb.rx_seen.items.size();
    endfunction

    virtual function eth_seg_seq_item rx_item(int unsigned i);
      return lb.rx_seen.items[i];
    endfunction

    virtual function bit mac_include_fcs();
      return lb.mac.cfg.include_fcs;
    endfunction

    virtual function bit client_include_fcs();
      return lb.client.cfg.include_fcs;
    endfunction

    virtual function void check_frame(eth_seg_seq_item exp, eth_seg_seq_item got, string what);
      lb.check_frame(exp, got, what);
    endfunction

    virtual function bit client_idle();
      return lb.client.tx_driver.is_idle() && lb.client.rx_monitor.is_idle();
    endfunction

    virtual function void check_dut_view();
      lb.check_dut_view();
    endfunction
  endclass

  class shm_mlink_checker extends aip_end_checker;
    eth_seg_shm_mlink_test test;

    function new(eth_seg_shm_mlink_test test);
      this.test = test;
    endfunction

    virtual function bit is_done();
      return test.rx_done();
    endfunction

    virtual function bit has_failed();
      return test.rx_failed();
    endfunction

    virtual function string status_detail();
      return test.rx_detail();
    endfunction
  endclass

  // 多链路：port_names 列出的端口（tb_shm 里 eth0..eth3 为 100G、eth4 为 400G）同时收发，各自 MAC 置 shm=1，共用本进程的
  // 一个 SHM 端口。每条链路的流由发送节点与链路名决定，收端按自己链路的名字逐字节、按序核对对端同名链路的帧（链路名可用
  // +<agent>.shm_link 改，两端 agent 与链路的对应可以不同）。参数 +shm_eth.<名>：self/peer、seed、tx_frames/rx_frames（每条
  // 链路）；quiet_port 不发帧的端口；drop_port/drop_index、corrupt_port/corrupt_index 在一个端口上漏发/改一帧（证明会失败）；
  // tx_errors_port 在该端口发坏 FCS（第 3 帧）与 EOP error（第 7 帧），需该端口 CLIENT include_fcs=1，对端以 rx_errors_link
  // 指出哪条链路的这两帧带错；ctrl_tx/ctrl_rx 为节点 Tcl 的控制信号数。hub 打开 shm_link_check 时 endpoint 两个方向各多一帧。
  class eth_seg_shm_mlink_test extends uvm_test;
    `uvm_component_utils(eth_seg_shm_mlink_test)

    shm_port_base ports[$];
    eth_seg_shm_hub hub;
    shm_tx_error_catcher tx_error_catcher;
    shm_transport_checker transport;
    shm_mlink_checker rx_checker;
    int unsigned self = 0, peer = 1, tx_frames = 0, rx_frames = 0, seed = 1, ctrl_tx = 0, ctrl_rx = 0;
    string port_names[];          // 不给时为 eth0..eth3（aip 字符串数组，+shm_eth.port_names=eth0,eth4）
    string quiet_port = "", drop_port = "", corrupt_port = "", tx_errors_port = "", rx_errors_link = "";
    int drop_index = -1, corrupt_index = -1;
    int unsigned link_frames;     // shm_link_check 的链路名集合帧（每个方向 0 或 1）

    function new(string name = "eth_seg_shm_mlink_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    static function shm_port_base make_port(string name);
      case (name)
        "eth0", "eth1", "eth2", "eth3": begin
          shm_port#(100) port = new(name);
          return port;
        end
        "eth4": begin
          shm_port#(400) port = new(name);
          return port;
        end
        default: return null;
      endcase
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      `aip_uint("shm_eth", int unsigned, self, self)
      `aip_uint("shm_eth", int unsigned, peer, peer)
      `aip_uint("shm_eth", int unsigned, tx_frames, tx_frames)
      `aip_uint("shm_eth", int unsigned, rx_frames, rx_frames)
      `aip_uint("shm_eth", int unsigned, seed, seed)
      `aip_str_list("shm_eth", port_names, "")
      `aip_string("shm_eth", quiet_port, quiet_port)
      `aip_string("shm_eth", drop_port, drop_port)
      `aip_int("shm_eth", int, drop_index, drop_index)
      `aip_string("shm_eth", corrupt_port, corrupt_port)
      `aip_int("shm_eth", int, corrupt_index, corrupt_index)
      `aip_string("shm_eth", tx_errors_port, tx_errors_port)
      `aip_string("shm_eth", rx_errors_link, rx_errors_link)
      `aip_uint("shm_eth", int unsigned, ctrl_tx, ctrl_tx)
      `aip_uint("shm_eth", int unsigned, ctrl_rx, ctrl_rx)
      if (port_names.size() == 0) port_names = '{"eth0", "eth1", "eth2", "eth3"};
      foreach (port_names[i]) begin
        shm_port_base port = make_port(port_names[i]);
        if (port == null)
          `uvm_fatal("SHM_TEST", {"shm_eth.port_names: unknown port '", port_names[i], "' (eth0..eth3 are 100G, eth4 is 400G)"})
        port.build(this);
        ports.push_back(port);
      end
      tx_error_catcher = new();
      uvm_report_cb::add(null, tx_error_catcher);
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      int unsigned total_tx;
      super.end_of_elaboration_phase(phase);
      foreach (ports[p]) begin
        if (!ports[p].find_link())
          `uvm_fatal("SHM_TEST", {ports[p].mac_path(), " needs +", ports[p].mac_path(), ".shm=1 inside an SHM cosim"})
        if (ports[p].name == tx_errors_port && !ports[p].client_include_fcs())
          `uvm_fatal("SHM_TEST", {"tx_errors_port needs +", ports[p].name, "_client.include_fcs=1 for the bad-FCS frame"})
        ports[p].expected_tx = (ports[p].name == quiet_port) ? 0 :
                               tx_frames - ((ports[p].name == drop_port && drop_index >= 0 && drop_index < tx_frames) ? 1 : 0);
        total_tx += ports[p].expected_tx;
      end
      hub = eth_seg_shm_hub::inst;
      if (hub == null || hub.links.size() != ports.size())
        `uvm_fatal("SHM_TEST", $sformatf("the SHM hub has %0d links, expected %0d", (hub == null) ? 0 : hub.links.size(),
                                         ports.size()))
      link_frames = hub.shm_link_check ? 1 : 0;
      // endpoint 计数含控制帧：期望为各链路数据帧，加本节点 Tcl 发出/收下的控制信号与链路名集合帧。
      transport = new(hub.endpoint, null, total_tx + ctrl_tx + link_frames, rx_frames * ports.size() + ctrl_rx + link_frames);
      rx_checker = new(this);
      aip_tcl_bridge::register_end_checker("shm_transport", transport);
      aip_tcl_bridge::register_end_checker("eth_shm_mlink_rx", rx_checker);
    endfunction

    function eth_seg_seq_item expected_rx(shm_port_base port, int unsigned k);
      byte unsigned body[];
      shm_stream::link_frame(seed, peer, port.link.link_name, k, body);
      return shm_stream::expected(body, k, port.mac_include_fcs(), port.link.link_name == rx_errors_link);
    endfunction

    // 各端口逐帧比对新到的对端帧（诊断以链路名开头），以 UVM_ERROR 计数增量判定该帧是否一致。
    function void check_new_frames();
      uvm_report_server server = uvm_report_server::get_server();
      foreach (ports[p])
        while (ports[p].checked < ports[p].rx_seen()) begin
          int errors = server.get_severity_count(UVM_ERROR);
          string what = $sformatf("%s: peer frame #%0d", ports[p].link.link_name, ports[p].checked);
          if (ports[p].checked >= rx_frames)
            `uvm_error("SHM_TEST_EXTRA", $sformatf("%s: unexpected (expected %0d)", what, rx_frames))
          else
            ports[p].check_frame(expected_rx(ports[p], ports[p].checked), ports[p].rx_item(ports[p].checked), what);
          if (server.get_severity_count(UVM_ERROR) != errors) ports[p].mismatches++;
          ports[p].checked++;
        end
    endfunction

    function int unsigned total_mismatches();
      int unsigned n = 0;
      foreach (ports[p]) n += ports[p].mismatches;
      return n;
    endfunction

    function bit rx_done();
      check_new_frames();
      if (total_mismatches() != 0) return 0;
      foreach (ports[p])
        if (ports[p].checked != rx_frames || ports[p].tx_seen() != ports[p].expected_tx ||
            ports[p].link.sent_frames != ports[p].expected_tx || !ports[p].link.is_idle() || !ports[p].client_idle())
          return 0;
      return 1;
    endfunction

    function bit rx_failed();
      check_new_frames();
      return total_mismatches() != 0;
    endfunction

    function string rx_detail();
      string text = "";
      foreach (ports[p])
        text = {text, (p == 0) ? "" : "; ", $sformatf("%s peer frames %0d/%0d mismatches=%0d sent %0d/%0d pending=%0d",
                ports[p].link.link_name, ports[p].checked, rx_frames, ports[p].mismatches, ports[p].link.sent_frames,
                ports[p].expected_tx, ports[p].link.pending())};
      return text;
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      foreach (ports[p]) begin
        string link = ports[p].link.link_name;
        bit errors = ports[p].name == tx_errors_port;
        if (ports[p].name == quiet_port) continue;
        for (int unsigned k = 0; k < tx_frames; k++) begin
          eth_seg_seq_item item;
          if (ports[p].name == drop_port && k == drop_index) continue;
          item = new($sformatf("shm_%s_tx_%0d", ports[p].name, k));
          shm_stream::link_frame(seed, self, link, k, item.frame_bytes);
          if (ports[p].name == corrupt_port && k == corrupt_index) item.frame_bytes[20] ^= 8'hff;
          item.inject_fcs_error = errors && shm_stream::bad_fcs(k);
          item.inject_error = errors && shm_stream::eop_error(k);
          ports[p].frames.push_back(item);
        end
      end
      // 各端口复位同时释放；之后 CLIENT 在所有端口上同时连续发帧，由 Tcl end_test 判定完成。
      fork
        begin
          foreach (ports[i]) begin
            automatic int p = i;
            fork
              ports[p].release_reset();
            join_none
          end
          wait fork;
        end
      join
      foreach (ports[i]) begin
        automatic int p = i;
        fork
          ports[p].send();
        join_none
      end
      aip_tcl_bridge::run_loop();
      final_check();
      phase.drop_objection(this);
    endtask

    // 把检查器的结论转成 UVM_ERROR，逐链路核对计数，并核对控制通道与带错帧诊断；每条链路打印一行汇总。
    function void final_check();
      int unsigned sent = 0, received = 0, link_errors = 0;
      int unsigned expected_errors = (tx_errors_port != "") ? 2 : 0;
      check_new_frames();
      if (transport.has_failed() || !transport.is_done())
        `uvm_error("SHM_TEST_TRANSPORT", {"shm_transport not complete: ", transport.status_detail()})
      if (rx_failed() || !rx_done())
        `uvm_error("SHM_TEST_RX", {"eth_shm_mlink_rx not complete: ", rx_detail()})
      foreach (ports[p]) begin
        eth_seg_shm_link_base l = ports[p].link;
        int unsigned errs = (ports[p].name == tx_errors_port) ? 2 : 0;
        ports[p].check_dut_view();
        if (ports[p].checked != rx_frames || l.sent_frames != ports[p].expected_tx || l.received_frames != rx_frames ||
            l.driven_frames != rx_frames || l.flushed_frames != 0 || l.dropped_frames != 0 || l.tx_errors != errs)
          `uvm_error("SHM_TEST_LINK", $sformatf({"%s: peer frames %0d/%0d sent=%0d/%0d received=%0d driven=%0d flushed=%0d ",
                                                 "dropped=%0d tx_errors=%0d/%0d"}, l.link_name, ports[p].checked, rx_frames,
                                                l.sent_frames, ports[p].expected_tx, l.received_frames, l.driven_frames,
                                                l.flushed_frames, l.dropped_frames, l.tx_errors, errs))
        sent += l.sent_frames;
        received += ports[p].checked;
        link_errors += l.tx_errors;
        `uvm_info("ETH_SHM_MLINK_LINK", $sformatf("link=%s port=%s agent=%s sent=%0d received=%0d mismatches=%0d",
                                                  l.link_name, ports[p].name, l.param_path, l.sent_frames,
                                                  ports[p].checked, ports[p].mismatches), UVM_NONE)
      end
      if (hub.ctrl_sent != ctrl_tx || hub.ctrl_received != ctrl_rx || hub.ctrl_dropped != 0 || hub.unclaimed() != "")
        `uvm_error("SHM_TEST_CTRL", $sformatf("control signals sent=%0d/%0d received=%0d/%0d dropped=%0d unclaimed='%s'",
                   hub.ctrl_sent, ctrl_tx, hub.ctrl_received, ctrl_rx, hub.ctrl_dropped, hub.unclaimed()))
      if (hub.shm_link_check && !hub.peer_links_seen)
        `uvm_error("SHM_TEST_LINKS", "shm_link_check is on but the peer link set never arrived")
      if (tx_error_catcher.msgs.size() != expected_errors)
        `uvm_error("SHM_TEST_TX_ERROR", $sformatf("%0d ETH_SHM_TX_ERROR reports, expected %0d",
                   tx_error_catcher.msgs.size(), expected_errors))
      else if (expected_errors != 0 &&
               (aip_str::str_find(tx_error_catcher.msgs[0], {tx_errors_port, "_mac: TX frame #3 "}) < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[0], "bad FCS") < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[1], {tx_errors_port, "_mac: TX frame #7 "}) < 0 ||
                aip_str::str_find(tx_error_catcher.msgs[1], "FCS inverted") < 0))
        `uvm_error("SHM_TEST_TX_ERROR", {"unexpected ETH_SHM_TX_ERROR text: ", tx_error_catcher.msgs[0], " | ",
                                         tx_error_catcher.msgs[1]})
      `uvm_info("ETH_SHM_COSIM_TEST_COMPLETE",
                $sformatf({"node=%0d links=%s sent=%0d received=%0d mismatches=%0d tx_errors=%0d ctrl_sent=%0d ",
                           "ctrl_received=%0d endpoint tx=%0d rx=%0d full_retry=%0d paused_retry=%0d"},
                          self, hub.link_names(), sent, received, total_mismatches(), link_errors, hub.ctrl_sent,
                          hub.ctrl_received, hub.endpoint.tx_frames, hub.endpoint.rx_frames, hub.endpoint.tx_full_retry,
                          hub.endpoint.tx_paused_retry), UVM_NONE)
    endfunction

    function void report_phase(uvm_phase phase);
      uvm_report_server server = uvm_report_server::get_server();
      super.report_phase(phase);
      if (server.get_severity_count(UVM_ERROR) == 0 && server.get_severity_count(UVM_FATAL) == 0)
        $display("*** TEST PASSED ***");
      else
        $display("*** TEST FAILED ***");
    endfunction
  endclass
endpackage
