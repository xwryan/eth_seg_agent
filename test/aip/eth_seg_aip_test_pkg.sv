// AIP 集成测试：Tcl 控制发包与改参，SV 只检查 bind agent monitor 的物理字节，不凭命令 OK 判通过。
package eth_seg_aip_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_aip_pkg::*;
  `include "uvm_macros.svh"

  class eth_aip_port_check #(int RATE = 100) extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_agent#(RATE) agt;
    int lengths[$], indices[$];
    int received = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 确认 agent 由 bind 创建且沿用 cfg 默认值。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_agent"}, agt))
        `uvm_fatal("AIP_TEST_HANDLE", "bound agent missing")
      if (agt.cfg.role != ETH_SEG_CLIENT || agt.cfg.is_active != UVM_ACTIVE ||
          agt.cfg.preamble_passthrough || agt.cfg.include_fcs || agt.cfg.traffic_load_pct != 100)
        `uvm_fatal("AIP_TEST_DEFAULT", "bind must retain cfg defaults")
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.tx_monitor.item_collected_port.connect(analysis_export);
    endfunction

    // 基础 sequence 的帧编号在每条命令中从零开始。
    function void expect_batch(int count, int length);
      for (int n = 0; n < count; n++) begin
        lengths.push_back(length);
        indices.push_back(n);
      end
    endfunction

    // 独立重建基础 sequence 的帧公式逐字节比较；超出期望数量的尾包同样报错。
    function void write(eth_seg_seq_item t);
      int length, index;
      received++;
      if (lengths.size() == 0) begin
        `uvm_error("AIP_TEST_EXTRA", "unexpected packet")
        return;
      end
      length = lengths.pop_front();
      index = indices.pop_front();
      if (t.frame_bytes.size() != length || t.aborted || t.fcs_present || t.direction != ETH_SEG_TX)
        `uvm_error("AIP_TEST_FORMAT", t.convert2string())
      else foreach (t.frame_bytes[b]) begin
        byte unsigned expected;
        if (b < 6) expected = 8'h10 + b;
        else if (b < 12) expected = 8'h20 + b - 6;
        else if (b == 12) expected = 8'h08;
        else if (b == 13) expected = 8'h00;
        else expected = byte'(index * 17 + b);
        if (t.frame_bytes[b] !== expected) begin
          `uvm_error("AIP_TEST_BYTES", $sformatf("packet=%0d byte=%0d differs", received, b))
          break;
        end
      end
    endfunction

    function bit complete();
      return lengths.size() == 0 && agt.tx_driver.is_idle() && agt.tx_monitor.is_idle();
    endfunction
  endclass

  class eth_seg_aip_test extends uvm_test;
    `uvm_component_utils(eth_seg_aip_test)
    eth_aip_port_check#(100) eth0, eth3;
    eth_aip_port_check#(200) eth1;
    eth_aip_port_check#(400) eth2;

    function new(string name = "eth_seg_aip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 期望对应 send.tcl：eth0 第二批改长度，其他端口不受影响。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      eth0 = new("eth0", this);
      eth1 = new("eth1", this);
      eth2 = new("eth2", this);
      eth3 = new("eth3", this);
      eth0.expect_batch(2, 256);
      eth0.expect_batch(1, 64);
      eth1.expect_batch(3, 128);
      eth2.expect_batch(1, 96);
      eth3.expect_batch(4, 512);
    endfunction

    // end_test 退出 bridge 后继续等待真实发送结束（最多 10 us）；
    // 静态表中四个对象互不相同，证明同速率的 eth0/eth3 没有共用 sqr。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      if (eth_seg_sequencer::sqr.num() != 4 ||
          eth_seg_sequencer::get_sqr("eth0") != eth0.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth1") != eth1.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth2") != eth2.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth3") != eth3.agt.sequencer ||
          eth0.agt.sequencer == eth3.agt.sequencer)
        `uvm_fatal("AIP_TEST_SQR", "four static sequencer bindings differ")
      wait (eth0.agt.cfg.vif.i_tx_rst_n && eth1.agt.cfg.vif.i_tx_rst_n &&
            eth2.agt.cfg.vif.i_tx_rst_n && eth3.agt.cfg.vif.i_tx_rst_n);
      aip_tcl_bridge::run_loop();
      for (int cycles = 0; cycles < 1000; cycles++) begin
        if (eth0.complete() && eth1.complete() && eth2.complete() && eth3.complete()) break;
        #10ns;
      end
      if (!eth0.complete() || !eth1.complete() || !eth2.complete() || !eth3.complete())
        `uvm_fatal("AIP_TEST_TIMEOUT", "Tcl requests did not complete on all four IPs")
      #20ns;
      if (eth0.received != 3 || eth1.received != 3 || eth2.received != 1 || eth3.received != 4)
        `uvm_fatal("AIP_TEST_COUNTS", "Tcl requests reached the wrong port or produced trailing packets")
      `uvm_info("ETH_AIP_TEST_COMPLETE", "four IPs: 3/3/1/4 frames matched; Tcl parameter isolation passed", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
