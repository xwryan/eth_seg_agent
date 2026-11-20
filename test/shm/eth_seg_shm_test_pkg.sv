// SHM 双节点联仿测试：每个节点一条 100G link，CLIENT lb0_client 代替 DUT 发 TX，MAC lb0_mac 由 +lb0_mac.shm=1 接入
// SHM fabric。两个节点由 SimFlow 的 BIDIR cosim 背靠背相连，按共享 seed 与流编号确定性生成帧，各自逐字节、按序核对
// 收到的对端帧，并经 AIP end_test 等待 shm_transport（endpoint 计数与排空）和本地比对两个检查器。
// 参数 +shm_eth.<名>（SimFlow 节点 params）：self/peer 流编号、tx_frames/rx_frames、seed；tx_errors/rx_errors 表示
// 本端/对端第 3 帧坏 FCS、第 7 帧 EOP error；drop_index/corrupt_index 是发送端故障注入，只用于证明丢帧或改帧会失败。
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

    static function bit bad_fcs(int unsigned k);
      return k == 3;
    endfunction

    static function bit eop_error(int unsigned k);
      return k == 7;
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
    int unsigned self = 0, peer = 1, tx_frames = 0, rx_frames = 0, seed = 1;
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
      transport = new(link.endpoint, null, expected_tx, rx_frames);
      rx_checker = new(this);
      aip_tcl_bridge::register_end_checker("shm_transport", transport);
      aip_tcl_bridge::register_end_checker("eth_shm_rx", rx_checker);
    endfunction

    // 对端第 k 帧在本端 MAC RX monitor 上的期望：字节原样，本端 include_fcs 时带 FCS（坏帧按发送端的改法），
    // rx_fcs_error 只在对端标了错的两帧为 1。
    function eth_seg_seq_item expected_rx(int unsigned k);
      eth_seg_seq_item exp = new("expected_rx");
      byte unsigned body[];
      bit [31:0] crc;
      shm_stream::frame(seed, peer, k, body);
      exp.fcs_present = lb0.mac.cfg.include_fcs;
      exp.rx_fcs_error = rx_errors && (shm_stream::bad_fcs(k) || shm_stream::eop_error(k));
      if (!exp.fcs_present) exp.frame_bytes = body;
      else begin
        crc = eth_seg_codec::crc32(body);
        if (rx_errors && shm_stream::eop_error(k)) crc = ~crc;
        else if (rx_errors && shm_stream::bad_fcs(k)) crc[31:24] ^= 8'h01;
        exp.frame_bytes = new[body.size() + 4];
        foreach (body[i]) exp.frame_bytes[i] = body[i];
        for (int b = 0; b < 4; b++) exp.frame_bytes[body.size()+b] = crc[b*8 +: 8];
      end
      return exp;
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
                $sformatf("node=%0d sent=%0d received=%0d mismatches=%0d tx_errors=%0d endpoint tx=%0d rx=%0d full_retry=%0d paused_retry=%0d",
                          self, link.sent_frames, checked, mismatches, link.tx_errors, link.endpoint.tx_frames,
                          link.endpoint.rx_frames, link.endpoint.tx_full_retry, link.endpoint.tx_paused_retry), UVM_NONE)
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
endpackage
