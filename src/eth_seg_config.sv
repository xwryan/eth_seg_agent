// agent 配置：编译期 RATE（贯穿 vif 类型，防止误连不同宽度接口）与运行期角色、格式、节奏策略。
// 子组件共享同一对象；运行中不应改变格式或队列深度。
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

  function new(string name = "eth_seg_config");
    super.new(name);
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
    return reason == "";
  endfunction
endclass
