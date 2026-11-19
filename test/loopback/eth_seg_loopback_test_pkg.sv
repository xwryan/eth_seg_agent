// loopback 测试：CLIENT agent 代替 DUT 发 TX，MAC agent 开 loopback 回灌 RX；由 MAC TX monitor 帧独立推算 RX 期望，
// 逐字节、按序核对 RX monitor。覆盖原样回环与 FCS 保留/剥离/补齐、带错 TX 帧报告、复位清队、溢出、注入共存、
// 运行期开关、plusarg 与 validate 拒绝。
package eth_seg_loopback_test_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  // 只捕获指定 ID、级别且消息含 text 的诊断并计数，其余照常上报。
  class lb_expected_report extends uvm_report_catcher;
    string id, text;
    uvm_severity severity;
    int caught;

    function new(string name = "lb_expected_report");
      super.new(name);
    endfunction

    virtual function action_e catch();
      if (get_id() == id && get_severity() == severity && aip_str::str_find(get_message(), text) >= 0) begin
        caught++;
        return CAUGHT;
      end
      return THROW;
    endfunction
  endclass

  // tb 在 run_test 前挂到 lbn 两个 agent 上，build 期 validate 拒绝由 lb_reject_case 核对。
  lb_expected_report reject_catcher;

  // 自测里的预期事件：按上报组件保存 ETH_LOOPBACK_TX_ERROR，UVM_ERROR 降为 UVM_INFO 后照常打印（日志无 warning）。
  class lb_tx_error_catcher extends uvm_report_catcher;
    string msgs[string][$];

    function new(string name = "lb_tx_error_catcher");
      super.new(name);
    endfunction

    virtual function action_e catch();
      string key;
      if (get_id() != "ETH_LOOPBACK_TX_ERROR") return THROW;
      key = get_client().get_full_name();
      if (!msgs.exists(key)) begin
        string none[$];
        msgs[key] = none;
      end
      msgs[key].push_back(get_message());
      if (get_severity() == UVM_ERROR) set_severity(UVM_INFO);
      return THROW;
    endfunction

    function int unsigned total();
      int unsigned n = 0;
      foreach (msgs[key]) n += msgs[key].size();
      return n;
    endfunction
  endclass

  // test build 时全局挂上；各 case 核对本 MAC 的报告，test 末尾核对总数（别处不得出现）。
  lb_tx_error_catcher tx_error_catcher;

  // spacing_ns 非零时帧间等待，使注入帧与回环帧在 sequencer 上交错。
  class lb_frame_seq extends uvm_sequence#(eth_seg_seq_item);
    eth_seg_seq_item frames[$];
    int unsigned spacing_ns;

    function new(string name = "lb_frame_seq");
      super.new(name);
    endfunction

    task body();
      foreach (frames[i]) begin
        if (spacing_ns != 0 && i != 0) #(spacing_ns * 1ns);
        start_item(frames[i]);
        finish_item(frames[i]);
      end
    endtask
  endclass

  // 持锁占住 MAC sequencer，回环帧只能停在 loopback 队列；release_lock 置位后解锁。
  class lb_blocker_seq extends uvm_sequence#(eth_seg_seq_item);
    bit release_lock, locked;

    function new(string name = "lb_blocker_seq");
      super.new(name);
    endfunction

    task body();
      lock();
      locked = 1;
      wait (release_lock);
      unlock();
      locked = 0;
    endtask
  endclass

  // 保存回调事务的副本。
  class lb_sink extends uvm_subscriber#(eth_seg_seq_item);
    eth_seg_seq_item items[$];

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void write(eth_seg_seq_item t);
      eth_seg_seq_item cp = new("observed");
      cp.copy(t);
      items.push_back(cp);
    endfunction
  endclass

  // 每条 link 一个 case：持有 bind 发布的 CLIENT/MAC agent 与复位控制，提供发帧、期望推算、比对与有界等待。
  class lb_case #(int RATE = 100) extends uvm_component;
    eth_seg_agent#(RATE) client, mac;
    virtual eth_loopback_control ctl;
    lb_sink tx_seen, rx_seen, rx_dut;
    string expected_tx_errors[$]; // 按 TX 顺序期望的 ETH_LOOPBACK_TX_ERROR 正文
    int unsigned next_id, checks;
    bit done;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    // 顶层 #0 后、run_test 前调用：MAC 角色与两端格式；wrapper 必须保留 loopback 默认 0。
    static function void configure(eth_seg_config#(RATE) c, m, bit client_fcs, mac_fcs, preamble);
      if (c == null || m == null || c.loopback || m.loopback)
        uvm_pkg::uvm_report_fatal("LB_INIT", "wrapper cfg missing or loopback default changed");
      m.role = ETH_SEG_MAC;
      m.enable_protocol_check = 0;
      c.include_fcs = client_fcs;
      m.include_fcs = mac_fcs;
      c.preamble_passthrough = preamble;
      m.preamble_passthrough = preamble;
    endfunction

    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      if (!uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_client_agent"}, client) ||
          !uvm_config_db#(eth_seg_agent#(RATE))::get(this, "", {get_name(), "_mac_agent"}, mac) ||
          !uvm_config_db#(virtual eth_loopback_control)::get(this, "", "control", ctl))
        `uvm_fatal("LB_HANDLE", "missing bound agents or reset control")
      tx_seen = new("tx_seen", this);
      rx_seen = new("rx_seen", this);
      rx_dut = new("rx_dut", this);
    endfunction

    // MAC TX monitor 是回环输入；MAC RX monitor 按 RX 编码格式解码输出，CLIENT RX monitor（DUT 侧）只核对线上字节相同。
    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      mac.tx_monitor.item_collected_port.connect(tx_seen.analysis_export);
      mac.rx_monitor.item_collected_port.connect(rx_seen.analysis_export);
      client.rx_monitor.item_collected_port.connect(rx_dut.analysis_export);
    endfunction

    // TX/RX 复位在时钟沿之外分开释放，再等 monitor 采到释放。
    task release_reset();
      #21ns ctl.tx_rst_n = 1;
      #7ns ctl.rx_rst_n = 1;
      #40ns;
    endtask

    // 帧号写入前两字节使每帧唯一；tag 区分 TX 回环帧与 RX 注入帧。
    function eth_seg_seq_item frame(int length, byte unsigned tag = 8'h5a, bit bad_fcs = 0, bit tx_error = 0);
      eth_seg_seq_item item = new($sformatf("lb_%0d", next_id));
      item.frame_bytes = new[length];
      foreach (item.frame_bytes[i]) item.frame_bytes[i] = byte'(next_id*29 + i*7 + RATE);
      item.frame_bytes[0] = tag;
      item.frame_bytes[1] = byte'(next_id);
      item.inject_fcs_error = bad_fcs;
      item.inject_error = tx_error;
      next_id++;
      return item;
    endfunction

    function void add_frames(ref eth_seg_seq_item q[$], input int count, input int length);
      for (int n = 0; n < count; n++) q.push_back(frame(length + n));
    endfunction

    task send(eth_seg_sequencer sqr, eth_seg_seq_item frames[$], int unsigned spacing_ns = 0);
      lb_frame_seq seq = new("lb_frames");
      seq.frames = frames;
      seq.spacing_ns = spacing_ns;
      seq.start(sqr);
    endtask

    // 独立期望：字节原样，MAC include_fcs 决定保留或剥离 TX FCS，TX 无 FCS 时 RX 端补正确 CRC；
    // rx_fcs_error 只看帧自带 FCS 的校验结果，TX EOP error 不改写 RX。
    function eth_seg_seq_item expected_rx(eth_seg_seq_item tx);
      eth_seg_seq_item exp = new("expected_rx");
      byte unsigned body[];
      bit [31:0] crc;
      int n;
      n = tx.frame_bytes.size() - (tx.fcs_present ? 4 : 0);
      body = new[n];
      foreach (body[i]) body[i] = tx.frame_bytes[i];
      if (!mac.cfg.include_fcs) exp.frame_bytes = body;
      else if (tx.fcs_present) exp.frame_bytes = tx.frame_bytes;
      else begin
        crc = eth_seg_codec::crc32(body);
        exp.frame_bytes = new[n+4];
        foreach (body[i]) exp.frame_bytes[i] = body[i];
        for (int b = 0; b < 4; b++) exp.frame_bytes[n+b] = crc[b*8 +: 8];
      end
      exp.fcs_present = mac.cfg.include_fcs;
      exp.rx_fcs_error = tx.fcs_present && !tx.fcs_ok;
      return exp;
    endfunction

    function bit tx_errored(eth_seg_seq_item t);
      return t.inject_error || (t.fcs_present && !t.fcs_ok);
    endfunction

    // 期望 TX monitor 第 index 帧报一条 ETH_LOOPBACK_TX_ERROR：帧号、长度、错误类型（坏 FCS 带收到/计算 CRC）与去向。
    function void expect_tx_error(int index, string outcome);
      eth_seg_seq_item t = tx_seen.items[index];
      string kind = "";
      if (t.inject_error) kind = "EOP error";
      if (t.fcs_present && !t.fcs_ok) begin
        byte unsigned body[];
        body = new[t.frame_bytes.size() - 4];
        foreach (body[i]) body[i] = t.frame_bytes[i];
        kind = {kind, (kind == "") ? "" : " + ",
                $sformatf("bad FCS (received 0x%08h, computed 0x%08h)", t.fcs, eth_seg_codec::crc32(body))};
      end
      expected_tx_errors.push_back($sformatf("TX frame #%0d (%0d bytes) has %s; %s", index, t.frame_bytes.size(), kind, outcome));
    endfunction

    // 本 MAC 的 ETH_LOOPBACK_TX_ERROR 与期望逐条一致（数量、顺序与正文），组件 tx_errors 计数相同。
    function void check_tx_errors();
      string key = mac.loopback.get_full_name();
      string got[$];
      checks++;
      if (tx_error_catcher.msgs.exists(key)) got = tx_error_catcher.msgs[key];
      if (got.size() != expected_tx_errors.size() || mac.loopback.tx_errors != expected_tx_errors.size()) begin
        `uvm_error("LB_TX_ERROR", $sformatf("%s: reported %0d, counted %0d, expected %0d", key, got.size(),
                                             mac.loopback.tx_errors, expected_tx_errors.size()))
        return;
      end
      foreach (got[i])
        if (aip_str::str_find(got[i], expected_tx_errors[i]) < 0)
          `uvm_error("LB_TX_ERROR", $sformatf("%s: report %0d '%s' lacks '%s'", key, i, got[i], expected_tx_errors[i]))
    endfunction

    // 注入帧只经 RX codec：MAC include_fcs 时补正确 CRC。
    function eth_seg_seq_item expected_injected(eth_seg_seq_item item);
      eth_seg_seq_item exp = new("expected_injected");
      bit [31:0] crc;
      int n = item.frame_bytes.size();
      exp.frame_bytes = new[n + (mac.cfg.include_fcs ? 4 : 0)];
      foreach (item.frame_bytes[i]) exp.frame_bytes[i] = item.frame_bytes[i];
      if (mac.cfg.include_fcs) begin
        crc = eth_seg_codec::crc32(item.frame_bytes);
        for (int b = 0; b < 4; b++) exp.frame_bytes[n+b] = crc[b*8 +: 8];
      end
      exp.fcs_present = mac.cfg.include_fcs;
      exp.rx_fcs_error = 0;
      return exp;
    endfunction

    // 逐字节比较 RX monitor 所见帧；保留 FCS 时 monitor 自算的 fcs_ok 必须与 rx_fcs_error 相反。
    function void check_frame(eth_seg_seq_item exp, eth_seg_seq_item got, string what);
      checks++;
      if (got.frame_bytes.size() != exp.frame_bytes.size()) begin
        `uvm_error("LB_LENGTH", $sformatf("%s: got %0d expected %0d bytes", what, got.frame_bytes.size(), exp.frame_bytes.size()))
        return;
      end
      foreach (exp.frame_bytes[i])
        if (got.frame_bytes[i] !== exp.frame_bytes[i]) begin
          `uvm_error("LB_BYTES", $sformatf("%s: byte %0d got %02x expected %02x", what, i, got.frame_bytes[i], exp.frame_bytes[i]))
          return;
        end
      if (got.direction != ETH_SEG_RX || got.aborted || got.fcs_present != exp.fcs_present ||
          got.rx_fcs_error != exp.rx_fcs_error || got.rx_error != 0 || got.rx_status != 1 ||
          (exp.fcs_present && got.fcs_ok == exp.rx_fcs_error))
        `uvm_error("LB_STATUS", $sformatf("%s: %s rx_fcs_error=%0b expected %0b", what, got.convert2string(),
                                           got.rx_fcs_error, exp.rx_fcs_error))
    endfunction

    // DUT 侧 monitor 与 MAC RX monitor 的线上字节逐帧一致（两侧 FCS 设置不同时只解释不同）。
    function void check_dut_view();
      checks++;
      if (rx_dut.items.size() != rx_seen.items.size()) begin
        `uvm_error("LB_DUT_VIEW", $sformatf("DUT side saw %0d frames, MAC RX monitor %0d", rx_dut.items.size(), rx_seen.items.size()))
        return;
      end
      foreach (rx_seen.items[i])
        if (rx_dut.items[i].frame_bytes != rx_seen.items[i].frame_bytes || rx_dut.items[i].aborted)
          `uvm_error("LB_DUT_VIEW", $sformatf("frame %0d differs between DUT side and MAC RX monitor", i))
    endfunction

    // rx_seen[rx_first +: n] 依次对应 tx_seen[tx_first +: n]。
    function void check_looped(int tx_first, int rx_first, int n, string what);
      for (int k = 0; k < n; k++)
        check_frame(expected_rx(tx_seen.items[tx_first+k]), rx_seen.items[rx_first+k], $sformatf("%s #%0d", what, k));
    endfunction

    // 有界等待 TX monitor 收齐、回环与 driver 排空、RX monitor 收齐，再多等几拍确认没有尾包。
    task drain(int unsigned tx_total, int unsigned rx_total, string what);
      for (int i = 0; i < 3000; i++) begin
        if (tx_seen.items.size() >= tx_total && rx_seen.items.size() >= rx_total && mac.loopback.is_idle() &&
            client.tx_driver.is_idle() && mac.rx_driver.is_idle()) break;
        #10ns;
      end
      #60ns;
      if (tx_seen.items.size() != tx_total || rx_seen.items.size() != rx_total || !mac.loopback.is_idle() ||
          !client.tx_driver.is_idle() || !mac.rx_driver.is_idle() || !client.rx_monitor.is_idle())
        `uvm_fatal("LB_DRAIN", $sformatf("%s: tx=%0d/%0d rx=%0d/%0d loopback pending=%0d", what,
                   tx_seen.items.size(), tx_total, rx_seen.items.size(), rx_total, mac.loopback.pending()))
    endtask

    // 持锁 sequence 在 MAC sequencer 上生效（有界等待）。
    task start_blocker(lb_blocker_seq blocker);
      fork
        blocker.start(mac.sequencer);
      join_none
      for (int i = 0; i < 100 && !blocker.locked; i++) #1ns;
      if (!blocker.locked) `uvm_fatal("LB_LOCK", "blocker did not lock the MAC sequencer")
    endtask

    // 持锁期间等 TX monitor 收齐且回环帧全部停在队列。
    task wait_queued(int unsigned tx_total, int unsigned queued, string what);
      for (int i = 0; i < 2000 && (tx_seen.items.size() < tx_total || mac.loopback.pending() < queued); i++) #10ns;
      #20ns;
      if (tx_seen.items.size() != tx_total || mac.loopback.pending() != queued)
        `uvm_fatal("LB_QUEUE", $sformatf("%s: tx=%0d/%0d queued=%0d/%0d", what, tx_seen.items.size(), tx_total,
                   mac.loopback.pending(), queued))
    endtask
  endclass

  // 基本回环：开关来源由 enable_by 指定（plusarg/cfg/override）；带错帧原样回环并逐条报告；
  // inject 时同时注入用户 RX 帧，按 tag 拆成两路分别核对顺序。
  class lb_basic_case #(int RATE = 100) extends lb_case#(RATE);
    string enable_by = "cfg";
    bit inject, periodic_rx;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      eth_seg_seq_item tx_frames[$], rx_frames[$], looped[$], injected[$];
      int lengths[12] = '{9, 15, 16, 17, 31, 33, 60, 64, 65, 127, 256, 1500};
      int switches;
      if (enable_by == "plusarg" && (!mac.cfg.loopback || !aip_cmdline_query::present(mac.get_full_name(), "loopback")))
        `uvm_fatal("LB_PLUSARG", {"plusarg +", mac.get_full_name(), ".loopback=1 was not applied at build"})
      if (enable_by == "cfg" && !mac.cfg.loopback) `uvm_fatal("LB_ENABLE", "cfg.loopback was not kept")
      if (periodic_rx && !(mac.cfg.rx_valid_pattern == ETH_SEG_PERIODIC && mac.cfg.rx_valid_high_cycles == 3 &&
                           mac.cfg.rx_valid_low_cycles == 1))
        `uvm_fatal("LB_PLUSARG", "rx_valid plusargs were not loaded into the MAC cfg")
      release_reset();
      if (enable_by == "override") aip_cmdline_override::set_val({mac.get_full_name(), ".loopback"}, "1");
      foreach (lengths[i]) tx_frames.push_back(frame(lengths[i], 8'h5a, i % 4 == 1, i % 5 == 2));
      if (inject) for (int i = 0; i < 8; i++) rx_frames.push_back(frame(20 + i*11, 8'hc3));
      fork
        send(client.sequencer, tx_frames);
        if (inject) send(mac.sequencer, rx_frames, 37);
      join
      drain(tx_frames.size(), tx_frames.size() + rx_frames.size(), "basic");
      if (!inject) check_looped(0, 0, tx_frames.size(), "looped");
      else begin
        foreach (rx_seen.items[i]) begin
          if (rx_seen.items[i].frame_bytes[0] == 8'hc3) injected.push_back(rx_seen.items[i]);
          else looped.push_back(rx_seen.items[i]);
          if (i > 0 && rx_seen.items[i].frame_bytes[0] != rx_seen.items[i-1].frame_bytes[0]) switches++;
        end
        if (looped.size() != tx_frames.size() || injected.size() != rx_frames.size() || switches < 2)
          `uvm_error("LB_COEXIST", $sformatf("looped=%0d injected=%0d switches=%0d", looped.size(), injected.size(), switches))
        else begin
          foreach (looped[k]) check_frame(expected_rx(tx_seen.items[k]), looped[k], $sformatf("looped #%0d", k));
          foreach (injected[k]) check_frame(expected_injected(rx_frames[k]), injected[k], $sformatf("injected #%0d", k));
        end
      end
      if (!mac.cfg.loopback || mac.loopback.looped_frames != tx_frames.size() || mac.loopback.dropped_frames != 0 ||
          mac.loopback.flushed_frames != 0)
        `uvm_error("LB_COUNT", $sformatf("looped=%0d dropped=%0d flushed=%0d", mac.loopback.looped_frames,
                                          mac.loopback.dropped_frames, mac.loopback.flushed_frames))
      // 带错帧（EOP error、坏 FCS）原样回环，每帧报一次。
      foreach (tx_seen.items[i]) if (tx_errored(tx_seen.items[i])) expect_tx_error(i, "queued for loopback unchanged");
      if (expected_tx_errors.size() == 0) `uvm_error("LB_TX_ERROR", "scenario produced no errored TX frame")
      check_tx_errors();
      check_dut_view();
      `uvm_info("LB_CASE_DONE", $sformatf("%s RATE=%0d enable_by=%s: %0d looped, %0d injected, checks=%0d",
                get_name(), RATE, enable_by, looped.size() + (inject ? 0 : tx_frames.size()), rx_frames.size(), checks), UVM_LOW)
      done = 1;
    endtask
  endclass

  // 运行期开关：aip override（Tcl set_param 的 SV 端）开/关；clear 后沿用最后读到的值，再直接改 cfg.loopback 打开。
  // 关闭期间的带错帧不回环也不报告，只有开启时那一帧报 ETH_LOOPBACK_TX_ERROR。
  class lb_toggle_case #(int RATE = 100) extends lb_case#(RATE);
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      string key = {mac.get_full_name(), ".loopback"};
      eth_seg_seq_item batch[$];
      if (mac.cfg.loopback) `uvm_fatal("LB_TOGGLE", "loopback must start disabled")
      release_reset();
      // 关闭期间的带错帧既不回环也不报告。
      add_frames(batch, 2, 40);
      batch.push_back(frame(60, 8'h5a, 0, 1));
      send(client.sequencer, batch);
      drain(3, 0, "default off");
      aip_cmdline_override::set_val(key, "1");
      batch.delete();
      add_frames(batch, 3, 50);
      batch.push_back(frame(77, 8'h5a, 0, 1));
      send(client.sequencer, batch);
      drain(7, 4, "override on");
      check_looped(3, 0, 4, "override on");
      expect_tx_error(6, "queued for loopback unchanged");
      aip_cmdline_override::set_val(key, "0");
      batch.delete();
      add_frames(batch, 1, 45);
      batch.push_back(frame(46, 8'h5a, 0, 1));
      send(client.sequencer, batch);
      drain(9, 4, "override off");
      aip_cmdline_override::clear(key);
      batch.delete();
      batch.push_back(frame(30));
      send(client.sequencer, batch);
      drain(10, 4, "override cleared");
      if (mac.cfg.loopback) `uvm_error("LB_TOGGLE", "clear_param must keep the last sampled value")
      mac.cfg.loopback = 1;
      batch.delete();
      add_frames(batch, 2, 90);
      send(client.sequencer, batch);
      drain(12, 6, "cfg on");
      check_looped(10, 4, 2, "cfg on");
      if (mac.loopback.looped_frames != 6 || mac.loopback.dropped_frames != 0)
        `uvm_error("LB_COUNT", $sformatf("looped=%0d dropped=%0d", mac.loopback.looped_frames, mac.loopback.dropped_frames))
      check_tx_errors();
      check_dut_view();
      `uvm_info("LB_CASE_DONE", $sformatf("%s: override on/off, clear and cfg toggle, checks=%0d", get_name(), checks), UVM_LOW)
      done = 1;
    endtask
  endclass

  // 复位：持锁让帧停在队列，RX 复位清队（期间到达的带错帧报 flushed by reset）；TX 复位既清队又截断进行中的长帧
  // （不回环）；恢复后只回环新帧。
  class lb_reset_case #(int RATE = 200) extends lb_case#(RATE);
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      lb_blocker_seq blocker;
      eth_seg_seq_item batch[$];
      int unsigned flushed0, aborted0;
      release_reset();
      // RX 复位清队；复位中解锁时 loopback 拿到 grant 但队列已空，占位帧被 rx_driver 丢弃。
      blocker = new("blocker_rx");
      start_blocker(blocker);
      add_frames(batch, 5, 64);
      send(client.sequencer, batch);
      wait_queued(5, 5, "before rx reset");
      flushed0 = mac.loopback.flushed_frames;
      @(negedge ctl.rx_clk);
      ctl.rx_rst_n = 0;
      #30ns;
      if (mac.loopback.pending() != 0 || mac.loopback.flushed_frames != flushed0 + 5)
        `uvm_error("LB_RX_RESET", $sformatf("pending=%0d flushed=%0d", mac.loopback.pending(), mac.loopback.flushed_frames - flushed0))
      // RX 复位期间到达的带错帧：丢弃，报告去向 flushed by reset。
      batch.delete();
      batch.push_back(frame(64, 8'h5a, 0, 1));
      send(client.sequencer, batch);
      for (int i = 0; i < 200 && tx_seen.items.size() < 6; i++) #1ns;
      #5ns;
      if (tx_seen.items.size() != 6 || mac.loopback.flushed_frames != flushed0 + 6)
        `uvm_error("LB_RX_RESET", $sformatf("frame during reset: tx=%0d flushed=%0d", tx_seen.items.size(),
                                             mac.loopback.flushed_frames - flushed0))
      expect_tx_error(5, "flushed by reset");
      blocker.release_lock = 1;
      #20ns;
      ctl.rx_rst_n = 1;
      #40ns;
      batch.delete();
      add_frames(batch, 3, 70);
      send(client.sequencer, batch);
      drain(9, 3, "after rx reset");
      check_looped(6, 0, 3, "after rx reset");
      // TX 复位：队列中的 2 帧被清，传输中的长帧被 monitor 丢弃。
      blocker = new("blocker_tx");
      start_blocker(blocker);
      batch.delete();
      add_frames(batch, 2, 64);
      send(client.sequencer, batch);
      wait_queued(11, 2, "before tx reset");
      flushed0 = mac.loopback.flushed_frames;
      aborted0 = mac.tx_monitor.aborted_packets;
      batch.delete();
      batch.push_back(frame(2048));
      send(client.sequencer, batch);
      for (int i = 0; i < 400 && !mac.tx_monitor.in_packet; i++) #1ns;
      if (!mac.tx_monitor.in_packet) `uvm_fatal("LB_TX_RESET", "long frame did not start")
      #12ns;
      ctl.tx_rst_n = 0;
      #30ns;
      if (mac.loopback.pending() != 0 || mac.loopback.flushed_frames != flushed0 + 2 ||
          mac.tx_monitor.aborted_packets != aborted0 + 1 || tx_seen.items.size() != 11)
        `uvm_error("LB_TX_RESET", $sformatf("pending=%0d flushed=%0d aborted=%0d tx=%0d", mac.loopback.pending(),
                   mac.loopback.flushed_frames - flushed0, mac.tx_monitor.aborted_packets - aborted0, tx_seen.items.size()))
      blocker.release_lock = 1;
      @(negedge ctl.tx_clk);
      #1ns ctl.tx_rst_n = 1;
      #40ns;
      batch.delete();
      add_frames(batch, 2, 100);
      send(client.sequencer, batch);
      drain(13, 5, "after tx reset");
      check_looped(11, 3, 2, "after tx reset");
      if (mac.loopback.looped_frames != 5 || mac.loopback.flushed_frames != 8)
        `uvm_error("LB_COUNT", $sformatf("looped=%0d flushed=%0d", mac.loopback.looped_frames, mac.loopback.flushed_frames))
      check_tx_errors();
      check_dut_view();
      `uvm_info("LB_CASE_DONE", $sformatf("%s: rx/tx reset flush and aborted frame, checks=%0d", get_name(), checks), UVM_LOW)
      done = 1;
    endtask
  endclass

  // 溢出：max_pending=3 来自 plusarg；持锁时第 4 帧起每帧一个 ETH_LOOPBACK_OVERFLOW（带错的第 6 帧报 dropped (queue full)），
  // 解锁后前 3 帧按序回环，之后恢复正常。
  class lb_overflow_case #(int RATE = 100) extends lb_case#(RATE);
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      lb_blocker_seq blocker = new("blocker");
      lb_expected_report overflow = new("overflow_catcher");
      eth_seg_seq_item batch[$];
      if (!mac.cfg.loopback || mac.cfg.max_pending != 3)
        `uvm_fatal("LB_PLUSARG", "plusargs +lbo_mac.loopback=1 +lbo_mac.max_pending=3 were not applied")
      release_reset();
      overflow.id = "ETH_LOOPBACK_OVERFLOW";
      overflow.severity = UVM_ERROR;
      overflow.text = "max_pending=3";
      uvm_report_cb::add(mac.loopback, overflow);
      start_blocker(blocker);
      // 溢出的第 6 帧带 EOP error：报告去向 dropped (queue full)。
      add_frames(batch, 5, 48);
      batch.push_back(frame(53, 8'h5a, 0, 1));
      send(client.sequencer, batch);
      wait_queued(6, 3, "overflow");
      expect_tx_error(5, "dropped (queue full)");
      uvm_report_cb::delete(mac.loopback, overflow);
      if (overflow.caught != 3 || mac.loopback.dropped_frames != 3)
        `uvm_error("LB_OVERFLOW", $sformatf("caught=%0d dropped=%0d", overflow.caught, mac.loopback.dropped_frames))
      blocker.release_lock = 1;
      drain(6, 3, "overflow survivors");
      check_looped(0, 0, 3, "overflow survivors");
      batch.delete();
      add_frames(batch, 2, 80);
      send(client.sequencer, batch);
      drain(8, 5, "after overflow");
      check_looped(6, 3, 2, "after overflow");
      check_tx_errors();
      check_dut_view();
      `uvm_info("LB_CASE_DONE", $sformatf("%s: 3 overflow errors, survivors and recovery in order, checks=%0d", get_name(), checks), UVM_LOW)
      done = 1;
    endtask
  endclass

  // validate 拒绝：plusarg 给 CLIENT 与 PASSIVE MAC（role/is_active 也来自 plusarg）开 loopback，build 各报一次 ETH_AGENT_CFG。
  class lb_reject_case #(int RATE = 100) extends lb_case#(RATE);
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void connect_phase(uvm_phase phase);
      super.connect_phase(phase);
      if (reject_catcher == null || reject_catcher.caught != 2)
        `uvm_fatal("LB_REJECT", "CLIENT and PASSIVE agents must each reject loopback once at build")
      uvm_report_cb::delete(client, reject_catcher);
      uvm_report_cb::delete(mac, reject_catcher);
      if (mac.cfg.role != ETH_SEG_MAC || mac.cfg.is_active != UVM_PASSIVE || mac.rx_driver != null ||
          mac.loopback != null || client.tx_driver == null || client.loopback != null)
        `uvm_fatal("LB_REJECT", "plusarg role/is_active were not applied before build decisions")
      // 拒绝已确认；清掉开关，避免 CLIENT tx_driver 在 run 期再次 validate 失败。
      client.cfg.loopback = 0;
      mac.cfg.loopback = 0;
    endfunction

    // 对象级：CLIENT、PASSIVE MAC 拒绝且原因明确，ACTIVE MAC 接受；本 link 复位保持断言。
    task run_phase(uvm_phase phase);
      eth_seg_config#(RATE) c = new("reject_cfg");
      string reason;
      string expected = "loopback requires role ETH_SEG_MAC and is_active UVM_ACTIVE";
      c.vif = client.cfg.vif;
      c.loopback = 1;
      if (c.validate(reason) || reason != expected) `uvm_error("LB_VALIDATE", {"CLIENT: ", reason})
      c.role = ETH_SEG_MAC;
      c.is_active = UVM_PASSIVE;
      if (c.validate(reason) || reason != expected) `uvm_error("LB_VALIDATE", {"PASSIVE MAC: ", reason})
      c.is_active = UVM_ACTIVE;
      if (!c.validate(reason)) `uvm_error("LB_VALIDATE", {"ACTIVE MAC: ", reason})
      c.loopback = 0;
      c.is_active = UVM_PASSIVE;
      if (!c.validate(reason)) `uvm_error("LB_VALIDATE", {"PASSIVE without loopback: ", reason})
      checks += 6;
      `uvm_info("LB_CASE_DONE", $sformatf("%s: build and object-level rejection, checks=%0d", get_name(), checks), UVM_LOW)
      done = 1;
    endtask
  endclass

  class eth_seg_loopback_test extends uvm_test;
    `uvm_component_utils(eth_seg_loopback_test)
    lb_basic_case#(100) lbp;
    lb_basic_case#(200) lbf;
    lb_basic_case#(400) lbs;
    lb_toggle_case#(100) lbt;
    lb_reset_case#(200) lbr;
    lb_overflow_case#(100) lbo;
    lb_reject_case#(100) lbn;

    function new(string name = "eth_seg_loopback_test", uvm_component parent = null);
      super.new(name, parent);
    endfunction

    // case 名即 link 名；lbp/lbo 由 plusarg、lbf/lbr 由 cfg、lbs 由 override 打开，lbt 运行期开关。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      tx_error_catcher = new("tx_error_catcher");
      uvm_report_cb::add(null, tx_error_catcher);
      lbp = new("lbp", this);
      lbp.enable_by = "plusarg";
      lbf = new("lbf", this);
      lbf.periodic_rx = 1;
      lbs = new("lbs", this);
      lbs.enable_by = "override";
      lbs.inject = 1;
      lbt = new("lbt", this);
      lbr = new("lbr", this);
      lbo = new("lbo", this);
      lbn = new("lbn", this);
    endfunction

    task run_phase(uvm_phase phase);
      phase.raise_objection(this);
      fork : completion_or_timeout
        begin
          wait (lbp.done && lbf.done && lbs.done && lbt.done && lbr.done && lbo.done && lbn.done);
          // 各 case 已逐条核对本 MAC；总数相等说明别处没有多报。
          if (tx_error_catcher.total() != lbp.expected_tx_errors.size() + lbf.expected_tx_errors.size() +
              lbs.expected_tx_errors.size() + lbt.expected_tx_errors.size() + lbr.expected_tx_errors.size() +
              lbo.expected_tx_errors.size())
            `uvm_error("LB_TX_ERROR", $sformatf("%0d ETH_LOOPBACK_TX_ERROR reports in total, more than expected",
                                                 tx_error_catcher.total()))
          `uvm_info("ETH_LOOPBACK_TEST_COMPLETE", $sformatf("7 links passed, checks=%0d, tx_error reports=%0d",
                    lbp.checks + lbf.checks + lbs.checks + lbt.checks + lbr.checks + lbo.checks + lbn.checks,
                    tx_error_catcher.total()), UVM_NONE)
        end
        begin
          #150us;
          `uvm_fatal("LB_GLOBAL_TIMEOUT", "loopback test did not complete within 150 us")
        end
      join_any
      disable completion_or_timeout;
      phase.drop_objection(this);
    endtask
  endclass
endpackage
