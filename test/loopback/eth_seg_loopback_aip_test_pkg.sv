// loopback Tcl 测试：set_param path=lb0_mac.loopback 开/关/开，lb0_send（AIP 示例 sequence）发 TX，
// 最后在回环进行中用 lb0_net_send 向 RX 注入 net_packet 报文；SV 不凭命令 OK 判通过，逐帧核对线上结果。
package eth_seg_loopback_aip_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_aip_pkg::*;
  import eth_net_packet_aip_pkg::*;
  import eth_seg_loopback_test_pkg::*;
  `include "uvm_macros.svh"

  // 示例 sequence 按 agent 名读参；命令映射到本 tb 的 CLIENT（TX）与 MAC（RX 注入）登记名。
  `aip_cmd_seq(lb0_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("lb0_client"))
  `aip_cmd_seq(lb0_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("lb0_mac"))

  class eth_seg_loopback_aip_test extends uvm_test;
    `uvm_component_utils(eth_seg_loopback_aip_test)
    lb_case#(100) lb0;
    lb_sink rx_sent;

    function new(string name = "eth_seg_loopback_aip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      lb0 = new("lb0", this);
      rx_sent = new("rx_sent", this);
    endfunction

    // rx_driver.sent_ap 含回环与注入两类帧，用来核对整条 RX 流的字节与顺序。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      lb0.mac.rx_driver.sent_ap.connect(rx_sent.analysis_export);
    endfunction

    // 期望对应 loopback.tcl：64B 帧 3 开、2 关、1 开、4 开（与 3 个 128B 注入报文并存）；RX 共 8 回环 + 3 注入。
    task run_phase(uvm_phase phase);
      int looped_tx[8] = '{0, 1, 2, 5, 6, 7, 8, 9};
      int n_looped, n_injected;
      phase.raise_objection(this);
      if (lb0.mac.cfg.loopback) `uvm_fatal("LB_TCL", "loopback must start disabled")
      lb0.release_reset();
      aip_tcl_bridge::run_loop();
      lb0.drain(10, 11, "tcl");
      foreach (lb0.rx_seen.items[i]) begin
        eth_seg_seq_item got = lb0.rx_seen.items[i];
        if (i >= rx_sent.items.size() || got.frame_bytes != rx_sent.items[i].frame_bytes)
          `uvm_error("LB_TCL_STREAM", $sformatf("RX frame %0d differs from rx_driver sent_ap", i))
        if (got.frame_bytes.size() == 64) begin
          if (n_looped < 8)
            lb0.check_frame(lb0.expected_rx(lb0.tx_seen.items[looped_tx[n_looped]]), got, $sformatf("tcl looped #%0d", n_looped));
          n_looped++;
        end
        else begin
          if (got.frame_bytes.size() != 128 || got.frame_bytes[12] != 8'h08 || got.frame_bytes[13] != 8'h00 ||
              got.frame_bytes[127] != 8'ha5 || got.aborted || got.rx_fcs_error)
            `uvm_error("LB_TCL_INJECT", $sformatf("injected frame %0d: %s", n_injected, got.convert2string()))
          n_injected++;
        end
      end
      lb0.check_dut_view();
      if (n_looped != 8 || n_injected != 3 || rx_sent.items.size() != 11 || lb0.mac.loopback.looped_frames != 8 ||
          !lb0.mac.cfg.loopback)
        `uvm_error("LB_TCL", $sformatf("looped=%0d injected=%0d sent=%0d counter=%0d", n_looped, n_injected,
                                        rx_sent.items.size(), lb0.mac.loopback.looped_frames))
      `uvm_info("ETH_LOOPBACK_AIP_TEST_COMPLETE", $sformatf("Tcl set_param toggle and net_send coexistence: 8 looped + 3 injected, checks=%0d",
                lb0.checks), UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
