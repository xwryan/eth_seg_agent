// agent 配置：编译期 RATE（贯穿 vif 类型，防止误连不同宽度接口）与运行期角色、格式、节奏策略。
// 子组件共享同一对象；运行中不应改变格式或队列深度。字段可按 agent 名经 aip_core 读参（load_params）。
class eth_seg_config #(int RATE = 100) extends uvm_object;
  `uvm_object_param_utils(eth_seg_config#(RATE))

  virtual eth_seg_if #(RATE) vif;
  int eth_rate_g = RATE;
  eth_seg_role_e role = ETH_SEG_CLIENT;
  uvm_active_passive_enum is_active = UVM_ACTIVE;
  bit preamble_passthrough = 0, include_fcs = 0;
  bit enable_protocol_check = 1;
  eth_seg_pattern_e ready_pattern = ETH_SEG_CONTINUOUS;
  eth_seg_pattern_e rx_valid_pattern = ETH_SEG_CONTINUOUS;
  int ready_high_cycles = 8, ready_low_cycles = 2, ready_high_pct = 70;
  int rx_valid_high_cycles = 8, rx_valid_low_cycles = 2, rx_valid_high_pct = 70;
  int traffic_load_pct = 100;
  bit random_load = 0;
  int load_min_pct = 10, load_max_pct = 100;
  int max_pending = 64;
  bit loopback = 0; // 仅 MAC active：TX monitor 整帧经 rx_driver 回灌 RX，逐帧重读
  bit shm = 0;      // 仅 MAC active，需可选 eth_seg_shm_pkg：TX 整帧进 SHM fabric，对端帧经 rx_driver 回灌 RX；与 loopback 互斥

  function new(string name = "eth_seg_config");
    super.new(name);
  endfunction

  // 每字段一个 aip 宏，参数名即字段名（+<path>.<field>=v），缺省取当前值；agent build 开头调用一次。
  // eth_rate_g/role/is_active/shm 决定组件构建，此后不再读取；运行中只有 loopback 按帧重读（Tcl set_param 可改）。
  function void load_params(string path);
    `aip_int(path, int, eth_rate_g, eth_rate_g)
    `aip_enum(path, eth_seg_role_e, role, role)
    `aip_enum(path, uvm_active_passive_enum, is_active, is_active)
    `aip_int(path, bit, preamble_passthrough, preamble_passthrough)
    `aip_int(path, bit, include_fcs, include_fcs)
    `aip_int(path, bit, enable_protocol_check, enable_protocol_check)
    `aip_enum(path, eth_seg_pattern_e, ready_pattern, ready_pattern)
    `aip_enum(path, eth_seg_pattern_e, rx_valid_pattern, rx_valid_pattern)
    `aip_int(path, int, ready_high_cycles, ready_high_cycles)
    `aip_int(path, int, ready_low_cycles, ready_low_cycles)
    `aip_int(path, int, ready_high_pct, ready_high_pct)
    `aip_int(path, int, rx_valid_high_cycles, rx_valid_high_cycles)
    `aip_int(path, int, rx_valid_low_cycles, rx_valid_low_cycles)
    `aip_int(path, int, rx_valid_high_pct, rx_valid_high_pct)
    `aip_int(path, int, traffic_load_pct, traffic_load_pct)
    `aip_int(path, bit, random_load, random_load)
    `aip_int(path, int, load_min_pct, load_min_pct)
    `aip_int(path, int, load_max_pct, load_max_pct)
    `aip_int(path, int, max_pending, max_pending)
    `aip_int(path, bit, shm, shm)
    void'(sample_loopback(path));
  endfunction

  // loopback 的唯一读参点：build 读一次，loopback 组件在每帧 EOP 再读，plusarg/Tcl override 可中途开关；
  // 未给出该参数时保留当前值（也可直接改 cfg.loopback），逐帧读取不刷屏。
  function bit sample_loopback(string path);
    if (aip_cmdline_query::present(path, "loopback"))
      `aip_int(path, bit, loopback, loopback)
    return loopback;
  endfunction

  // 把本帧占用的有效段数换算为包后 idle 段数（TX/RX 共用）：随机模式每帧抽一次负载百分比，向上取整使目标负载为上限；
  // 显式 gap 为下限，取两者较大值；ready/valid 气泡不消费这些段；负数或溢出 fatal。
  function int gap_after_frame(input int unsigned frame_segments, input int minimum_gap);
    int pct;
    longint unsigned load_gap;
    if (minimum_gap < 0) begin
      `uvm_fatal("ETH_SEG_GAP", "gap_segments must be nonnegative")
      return 0;
    end
    pct = random_load ? $urandom_range(load_max_pct, load_min_pct) : traffic_load_pct;
    if (pct < 1 || pct > 100) begin
      `uvm_fatal("ETH_SEG_LOAD", "load percentage must be 1..100")
      return 0;
    end
    load_gap = (longint'(frame_segments) * (100-pct) + pct-1) / pct;
    if (load_gap > 32'h7fffffff) begin
      `uvm_fatal("ETH_SEG_GAP", "computed gap exceeds supported segment count")
      return 0;
    end
    return (load_gap > minimum_gap) ? int'(load_gap) : minimum_gap;
  endfunction

  // 只返回首个违例原因、不发 report，由调用者在自己的组件上下文中 fatal。
  function bit validate(output string reason);
    reason = "";
    if (!(RATE inside {100, 200, 400})) reason = "RATE must be 100, 200 or 400";
    else if (eth_rate_g != RATE) reason = "eth_rate_g does not match parameter RATE";
    else if (vif == null) reason = "virtual interface is null";
    else if (!(role inside {ETH_SEG_CLIENT, ETH_SEG_MAC})) reason = "invalid role";
    else if (!(is_active inside {UVM_ACTIVE, UVM_PASSIVE})) reason = "invalid active/passive mode";
    else if (!(ready_pattern inside {ETH_SEG_CONTINUOUS, ETH_SEG_PERIODIC, ETH_SEG_RANDOM}) ||
             !(rx_valid_pattern inside {ETH_SEG_CONTINUOUS, ETH_SEG_PERIODIC, ETH_SEG_RANDOM}))
      reason = "invalid timing pattern";
    else if (ready_high_cycles <= 0 || ready_low_cycles <= 0 ||
             rx_valid_high_cycles <= 0 || rx_valid_low_cycles <= 0)
      reason = "periodic high and low cycle counts must be positive";
    else if (!(ready_high_pct inside {[0:100]}) || !(rx_valid_high_pct inside {[0:100]}))
      reason = "timing percentage must be 0..100";
    else if (!(traffic_load_pct inside {[1:100]}) || !(load_min_pct inside {[1:100]}) ||
             !(load_max_pct inside {[1:100]}) || load_min_pct > load_max_pct)
      reason = "load percentage must be 1..100 with min <= max";
    else if (max_pending <= 0) reason = "max_pending must be positive";
    else if (loopback && !(role == ETH_SEG_MAC && is_active == UVM_ACTIVE))
      reason = "loopback requires role ETH_SEG_MAC and is_active UVM_ACTIVE";
    else if (shm && !(role == ETH_SEG_MAC && is_active == UVM_ACTIVE))
      reason = "shm requires role ETH_SEG_MAC and is_active UVM_ACTIVE";
    else if (shm && loopback) reason = "loopback and shm are mutually exclusive";
    return reason == "";
  endfunction
endclass
