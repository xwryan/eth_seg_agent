// net_packet AIP 集成测试：Tcl 命令驱动四个 bind agent，期望由 SV 显式构造（不调用 load_params 或转换 sequence）；
// 另用 pin SOP 槽位确认命令中的 rate/clock/IFG/随机范围真正影响发送间隔。
package eth_net_packet_aip_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_net_packet_pkg::*;
  import eth_net_packet_aip_pkg::*;
  import eth_net_packet_test_pkg::*;
  `include "uvm_macros.svh"

  class eth_net_aip_port #(int RATE = 100) extends uvm_component;
    eth_seg_agent#(RATE) agt;
    eth_net_sink sink, sampled;
    eth_base_seq sampler;
    int expected_count = 0;
    longint sop_slots[$];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 确认 bind 保持默认 CLIENT、无前导、无 FCS。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_agent"}, agt))
        `uvm_fatal("ETH_NET_AIP_HANDLE", "bound agent missing")
      if (agt.cfg.role != ETH_SEG_CLIENT || agt.cfg.preamble_passthrough || agt.cfg.include_fcs)
        `uvm_fatal("ETH_NET_AIP_DEFAULT", "bound agent defaults changed")
      sink = new("sink", this);
      sampled = new("sampled", this);
      sampler = new("sampler");
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      agt.tx_monitor.item_collected_port.connect(sink.analysis_export);
    endfunction

    function void expect_batch(input packet p, input int count);
      repeat (count) begin
        sink.expect_bytes(p.raw_data, 0, 0, ETH_SEG_TX);
        sampled.expect_bytes(p.raw_data, 0, 0, ETH_SEG_TX);
      end
      expected_count += count;
    endfunction

    // 在命令对象创建前注册持久订阅，多条 Tcl 命令复用同一缓存消费者。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      sampler.set_sequencer(eth_seg_sequencer::get_sqr(agt.get_full_name()));
      sampler.subscribe(ETH_SEG_TX);
    endfunction

    // 槽位只按有效拍计数，包内与空闲 segment 各占一个槽；MAC ready 持续为 1，批内间隔即可核对命令参数。
    task track_sop();
      longint slot = 0;
      bit in_packet = 0;
      forever begin
        @(agt.cfg.vif.tx_cb);
        if (!agt.cfg.vif.tx_cb.i_tx_rst_n || !agt.cfg.vif.tx_cb.i_tx_mac_valid) continue;
        for (int s = 0; s < RATE/25; s++) begin
          if (!in_packet && agt.cfg.vif.tx_cb.i_tx_mac_inframe[s]) begin
            sop_slots.push_back(slot);
            in_packet = 1;
          end else if (in_packet && !agt.cfg.vif.tx_cb.i_tx_mac_inframe[s]) in_packet = 0;
          slot++;
        end
      end
    endtask

    // 与 pin 计数器并行运行，避免串行消费漏掉同拍多包。
    task sample_packets();
      forever begin
        eth_seg_seq_item item;
        sampler.mon_xaction(item, ETH_SEG_TX);
        if (item == null) break;
        sampled.write(item);
      end
    endtask

    task run_phase(uvm_phase phase);
      fork track_sop(); sample_packets(); join
    endtask

    function bit complete();
      return sink.expected.size() == 0 && sink.received == expected_count &&
             sampled.expected.size() == 0 && sampled.received == expected_count &&
             sop_slots.size() == expected_count && agt.monitor_hub.is_idle() &&
             agt.tx_driver.is_idle() && agt.tx_driver.idle_left == 0 && agt.tx_monitor.is_idle();
    endfunction
  endclass

  class eth_net_packet_aip_test extends uvm_test;
    `uvm_component_utils(eth_net_packet_aip_test)
    eth_net_aip_port#(100) eth0, eth3;
    eth_net_aip_port#(200) eth1;
    eth_net_aip_port#(400) eth2;

    function new(string name = "eth_net_packet_aip_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // 四个端口包含重复的 100G，验证按名字查找而非按 RATE 共享 sqr。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      eth0 = new("eth0", this);
      eth1 = new("eth1", this);
      eth2 = new("eth2", this);
      eth3 = new("eth3", this);
    endfunction

    // 字段与 send.tcl 一一对应，不经 AIP 参数解析或被测 packet_to_item。
    function packet reference_frame(input packet_template_e tmpl, input int length,
                                    input bit [47:0] dst_mac = 0,
                                    input byte unsigned payload_byte = 8'ha5);
      packet p = new();
      eth_header eh;

      p.build_from_template(tmpl);
      p.pkt_len = length;
      eh = p.get_eth();
      eh.dst_mac = dst_mac;
      p.payload_mode = PAYLOAD_FIXED;
      p.payload_fixed_val = payload_byte;
      p.do_pack();
      return p;
    endfunction

    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (eth_seg_sequencer::get_sqr("eth0") != eth0.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth1") != eth1.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth2") != eth2.agt.sequencer ||
          eth_seg_sequencer::get_sqr("eth3") != eth3.agt.sequencer ||
          eth0.agt.sequencer == eth3.agt.sequencer)
        `uvm_fatal("ETH_NET_AIP_SQR", "static sequencer isolation failed")
      eth0.expect_batch(reference_frame(ETH_IPV4_UDP, 256), 2);
      eth0.expect_batch(reference_frame(ETH_IPV4_UDP, 64, 48'h123456789abc, 8'h5a), 1);
      eth1.expect_batch(reference_frame(ETH_IPV6_TCP, 128, 48'hfedcba987654), 3);
      eth2.expect_batch(reference_frame(ETH_IPV4_UDP_ROCEV2, 129), 1);
      eth3.expect_batch(reference_frame(ETH_IPV4_UDP, 512, 48'h010203040506), 4);
    endfunction

    // end_test 只停止命令循环，仍须等待物理发包完成。
    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      wait (eth0.agt.cfg.vif.i_tx_rst_n && eth1.agt.cfg.vif.i_tx_rst_n &&
            eth2.agt.cfg.vif.i_tx_rst_n && eth3.agt.cfg.vif.i_tx_rst_n);
      aip_tcl_bridge::run_loop();
      for (int cycles = 0; cycles < 2000; cycles++) begin
        if (eth0.complete() && eth1.complete() && eth2.complete() && eth3.complete()) break;
        #10ns;
      end
      #20ns;
      if (!eth0.complete() || !eth1.complete() || !eth2.complete() || !eth3.complete())
        `uvm_fatal("ETH_NET_AIP_TIMEOUT", "Tcl network packets did not match on all four ports")
      // 256B+24B 在 50G/415.0390625MHz/4段下首包总预算 74.375 槽，向上取整为75。
      if (eth0.sop_slots[1]-eth0.sop_slots[0] != 75)
        `uvm_error("ETH_NET_AIP_RATE", "per-call real rate/clock arguments did not produce 75-slot spacing")
      // 128B+4B FCS+8B前导+16B IFG 在200G/8段下两包累计预算为41.4375槽。
      if (eth1.sop_slots[1]-eth1.sop_slots[0] != 21 || eth1.sop_slots[2]-eth1.sop_slots[0] != 42)
        `uvm_error("ETH_NET_AIP_IFG", "per-call IFG or cumulative rounding mismatch")
      // 随机25..75G按每个512B包检查，允许一个槽的累计取整边界误差。
      for (int n = 1; n < 4; n++) begin
        longint delta = eth3.sop_slots[n]-eth3.sop_slots[n-1];
        if (delta < 94 || delta > 285)
          `uvm_error("ETH_NET_AIP_RANDOM", "random rate arguments did not bound physical spacing")
      end
      `uvm_info("ETH_NET_AIP_TEST_COMPLETE", "4 named IPs: 3/3/1/4 network frames matched, including runtime parameters and RoCEv2 ICRC", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
