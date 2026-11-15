// 流控物理带宽测试：三速率 × 四格式双向并发；用 pin 侧 SOP 位置检查取整误差、真实时间检查吞吐，不用计划统计自证。
package eth_flow_test_pkg;
  timeunit 1ns;
  timeprecision 1fs;
  import uvm_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  import eth_flow_pkg::*;
  import eth_net_packet_test_pkg::*;
  `include "uvm_macros.svh"

  // 预构造报文，使期望可在启动前登记。
  class flow_test_seq extends eth_flow_seq;
    packet frames[$];

    function new(string name = "flow_test_seq");
      super.new(name);
    endfunction

    // 越界直接失败，不回退默认帧，以免掩盖 count 错误。
    virtual function packet create_packet(int unsigned packet_index);
      if (packet_index >= frames.size()) begin
        `uvm_fatal("FLOW_TEST_INDEX", "packet index outside supplied batch")
        return null;
      end
      return frames[packet_index];
    endfunction
  endclass

  class flow_case #(int RATE = 100) extends uvm_component;
    localparam int SEGMENTS = RATE/25;
    real clock_hz = 415039062.5;
    virtual eth_seg_if#(RATE) vif;
    eth_seg_agent#(RATE) client, mac;
    eth_seg_config#(RATE) cc, mc;
    eth_net_sink tx_sink, rx_sink;
    int format_mode;
    bit done;
    longint tx_sop[$], rx_sop[$];
    realtime tx_ns[$], rx_ns[$];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 同一接口上创建互补角色，并关闭旧负载节流。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(virtual eth_seg_if#(RATE))::get(this, "", "vif", vif))
        `uvm_fatal("FLOW_TEST_VIF", "missing interface")
      void'($value$plusargs("FLOW_CLOCK_HZ=%f", clock_hz));
      cc = new("client_cfg"); mc = new("mac_cfg");
      cc.vif = vif; mc.vif = vif;
      mc.role = ETH_SEG_MAC;
      cc.preamble_passthrough = format_mode[1]; mc.preamble_passthrough = format_mode[1];
      cc.include_fcs = format_mode[0]; mc.include_fcs = format_mode[0];
      client = eth_seg_agent#(RATE)::type_id::create("client", this);
      mac = eth_seg_agent#(RATE)::type_id::create("mac", this);
      client.cfg = cc; mac.cfg = mc;
      tx_sink = new("tx_sink", this); rx_sink = new("rx_sink", this);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mac.tx_monitor.item_collected_port.connect(tx_sink.analysis_export);
      client.rx_monitor.item_collected_port.connect(rx_sink.analysis_export);
    endfunction

    // 记录每个 SOP 的有效 segment 索引与采样时间；拍内 segment 偏移只用于排序，不表示引脚在子周期变化。
    task track(bit tx);
      longint slot = 0;
      bit in_packet = 0, valid;
      bit [SEGMENTS-1:0] inframe;
      forever begin
        if (tx) begin
          @(vif.tx_cb);
          valid = vif.tx_cb.i_tx_rst_n && vif.tx_cb.i_tx_mac_valid;
          inframe = vif.tx_cb.i_tx_mac_inframe;
        end else begin
          @(vif.rx_cb);
          valid = vif.rx_cb.i_rx_rst_n && vif.rx_cb.o_rx_mac_valid;
          inframe = vif.rx_cb.o_rx_mac_inframe;
        end
        if (!valid) continue;
        for (int s = 0; s < SEGMENTS; s++) begin
          if (!in_packet && inframe[s]) begin
            if (tx) begin
              tx_sop.push_back(slot);
              tx_ns.push_back($realtime + s * 1.0e9 / (clock_hz * SEGMENTS));
            end else begin
              rx_sop.push_back(slot);
              rx_ns.push_back($realtime + s * 1.0e9 / (clock_hz * SEGMENTS));
            end
            in_packet = 1;
          end else if (in_packet && !inframe[s]) in_packet = 0;
          slot++;
        end
      end
    endtask

    // 直接构造 raw_data，覆盖短帧补齐、segment 临界长度、大帧和随机长度。
    function packet make_frame(int index);
      packet p = new();
      int length;
      case (index % 16)
        0: length = 14;
        1: length = 60;
        2: length = 61;
        3: length = 63;
        4: length = 64;
        5: length = 65;
        6: length = 1514;
        7: length = 4095;
        default: length = $urandom_range(60, 2000);
      endcase
      repeat (length) p.raw_data.push_back($urandom_range(0, 255));
      return p;
    endfunction

    // 期望只对短帧补零；记录源长度以确认产品未修改借入的报文。
    function void expect_frame(packet p, bit tx);
      byte unsigned bytes[$] = p.raw_data;
      while (bytes.size() < 60) bytes.push_back(0);
      if (tx) tx_sink.expect_bytes(bytes, format_mode[1], format_mode[0], ETH_SEG_TX);
      else rx_sink.expect_bytes(bytes, format_mode[1], format_mode[0], ETH_SEG_RX);
    endfunction

    // 所有方向包含最后一个包后的 gap 都清空才切换模式，避免前后批次互相污染。
    task drain();
      for (int cycle = 0; cycle < 200000; cycle++) begin
        @(negedge vif.i_clk_tx);
        if (client.tx_driver.is_idle() && mac.rx_driver.is_idle() &&
            client.tx_driver.idle_left == 0 && mac.rx_driver.idle_left == 0 &&
            tx_sink.expected.size() == 0 && rx_sink.expected.size() == 0) return;
      end
      `uvm_fatal("FLOW_TEST_DRAIN", "physical traffic did not drain")
    endtask

    // 用逐帧 pin SOP 前缀检查预算：固定速率的累计误差只能在 [0,1) 段；
    // 混合包长不能用平均包长代替，随机速率只检查范围。
    function void check_rate(flow_test_seq seq, bit tx, int stage);
      longint slots[$];
      realtime times[$];
      real wire_sum = 0.0, expected_slots, delta, actual_rate;
      real low_slots = 0.0, high_slots = 0.0;
      int body_size;

      if (tx) begin slots = tx_sop; times = tx_ns; end
      else begin slots = rx_sop; times = rx_ns; end
      if (slots.size() != seq.count || times.size() != seq.count) begin
        `uvm_error("FLOW_TEST_COUNT", "missing or extra physical SOP")
        return;
      end
      for (int n = 1; n < seq.count; n++) begin
        body_size = seq.frames[n-1].raw_data.size();
        if (body_size < 60) body_size = 60;
        wire_sum += body_size + 24;
        if (!seq.random_rate) begin
          expected_slots = wire_sum * 8.0 / seq.rate_gbps * (clock_hz / 1.0e9) * SEGMENTS;
          delta = real'(slots[n] - slots[0]) - expected_slots;
          if (delta < -0.00001 || delta >= 1.00001)
            `uvm_error("FLOW_TEST_ROUND", $sformatf("stage=%0d tx=%0b n=%0d delta_slots=%f", stage, tx, n, delta))
        end else begin
          low_slots = wire_sum * 8.0 / seq.rate_max_gbps * (clock_hz / 1.0e9) * SEGMENTS;
          high_slots = wire_sum * 8.0 / seq.rate_min_gbps * (clock_hz / 1.0e9) * SEGMENTS;
          if (slots[n]-slots[0] < low_slots-0.00001 || slots[n]-slots[0] > high_slots+1.00001)
            `uvm_error("FLOW_TEST_RANDOM", "physical pacing outside random rate bounds")
        end
      end
      actual_rate = wire_sum * 8.0 / (times[$]-times[0]);
      if (!seq.random_rate && stage != 3 &&
          (actual_rate > seq.rate_gbps * 1.00001 || actual_rate < seq.rate_gbps * 0.999))
        `uvm_error("FLOW_TEST_RATE", $sformatf("target=%f measured=%f", seq.rate_gbps, actual_rate))
      if (stage == 3 && actual_rate >= seq.rate_gbps * 0.9)
        `uvm_error("FLOW_TEST_BUBBLE", "backpressure/valid bubbles did not lower physical throughput")
      `uvm_info("ETH_FLOW_RATE", $sformatf("RATE=%0d fmt=%0d stage=%0d tx=%0b measured=%0.6f Gbps frames=%0d", RATE, format_mode, stage, tx, actual_rate, seq.count), UVM_LOW)
    endfunction

    // 只捕获指定 fatal：速率上限、时钟容量、非法范围、叠加旧负载与非法 count；
    // 每次新建 sequence，确认错误路径不泄漏 sequencer 锁。
    task negative_cases();
      eth_net_expected_fatal catcher = new();
      for (int n = 0; n < 5; n++) begin
        flow_test_seq seq = new("negative");
        seq.frames.push_back(make_frame(4));
        case (n)
          0: begin seq.rate_gbps = RATE+1; catcher.expected_id = "ETH_FLOW_CFG"; end
          1: begin seq.clk_freq_hz = 1000000.0; catcher.expected_id = "ETH_FLOW_CAPACITY"; end
          2: begin seq.random_rate = 1; catcher.expected_id = "ETH_FLOW_CFG"; end
          3: begin cc.traffic_load_pct = 50; catcher.expected_id = "ETH_FLOW_LOAD"; end
          4: begin seq.count = 0; catcher.expected_id = "ETH_NET_COUNT"; end
        endcase
        uvm_report_cb::add(null, catcher);
        seq.start(client.sequencer);
        uvm_report_cb::delete(null, catcher);
        cc.traffic_load_pct = 100;
      end
      if (catcher.caught != 5) `uvm_fatal("FLOW_TEST_NEGATIVE", "expected five exact diagnostics")
    endtask

    // 连续满速、半速、随机速率、ready/valid 气泡逐阶段验证；前后批次不共享模型。
    task exercise();
      wait(vif.i_tx_rst_n && vif.i_rx_rst_n);
      repeat (4) @(negedge vif.i_clk_tx);
      if (RATE == 400 && format_mode == 0) negative_cases();
      for (int stage = 0; stage < 4; stage++) begin
        flow_test_seq tx = new("tx_flow"), rx = new("rx_flow");
        tx.count = 128; rx.count = 128;
        tx.clk_freq_hz = clock_hz; rx.clk_freq_hz = clock_hz;
        tx.rate_gbps = (stage == 1) ? RATE/2.0 : real'(RATE);
        rx.rate_gbps = tx.rate_gbps;
        tx.random_rate = (stage == 2); rx.random_rate = tx.random_rate;
        tx.rate_min_gbps = RATE/4.0; rx.rate_min_gbps = tx.rate_min_gbps;
        tx.rate_max_gbps = RATE*0.75; rx.rate_max_gbps = tx.rate_max_gbps;
        mc.ready_pattern = (stage == 3) ? ETH_SEG_PERIODIC : ETH_SEG_CONTINUOUS;
        mc.rx_valid_pattern = (stage == 3) ? ETH_SEG_RANDOM : ETH_SEG_CONTINUOUS;
        tx_sop.delete(); rx_sop.delete(); tx_ns.delete(); rx_ns.delete();
        repeat (tx.count) begin
          packet p = make_frame(tx.frames.size());
          tx.frames.push_back(p); rx.frames.push_back(p);
          expect_frame(p, 1); expect_frame(p, 0);
        end
        fork tx.start(client.sequencer); rx.start(mac.sequencer); join
        drain();
        check_rate(tx, 1, stage); check_rate(rx, 0, stage);
        if (tx.frames[0].raw_data.size() != 14)
          `uvm_error("FLOW_TEST_ALIAS", "short-frame padding modified the source packet")
      end
      done = 1;
    endtask

    task run_phase(uvm_phase phase);
      fork track(1); track(0); exercise(); join
    endtask
  endclass

  // 十二条 link 覆盖三个 RATE 与全部前导/FCS 组合。
  class eth_flow_test extends uvm_test;
    `uvm_component_utils(eth_flow_test)
    flow_case#(100) c100[4];
    flow_case#(200) c200[4];
    flow_case#(400) c400[4];

    function new(string name = "eth_flow_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      for (int m = 0; m < 4; m++) begin
        c100[m] = new($sformatf("r100_m%0d",m),this); c100[m].format_mode = m;
        c200[m] = new($sformatf("r200_m%0d",m),this); c200[m].format_mode = m;
        c400[m] = new($sformatf("r400_m%0d",m),this); c400[m].format_mode = m;
      end
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      for (int m = 0; m < 4; m++) wait(c100[m].done && c200[m].done && c400[m].done);
      `uvm_info("ETH_FLOW_TEST_COMPLETE", "12 links: mixed lengths, full/half/random rates, format switches, bubbles and five negative cases", UVM_NONE)
      phase.drop_objection(this);
    endtask
  endclass
endpackage
