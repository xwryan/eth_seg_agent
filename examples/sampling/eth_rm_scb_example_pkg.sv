// 采样集成示例：借用已有 MAC agent，RX 整包交 RM 预测、TX 整包交 SCB 比较。
// 示例复位策略：任一方向复位即丢弃整条链路的在途预测，业务环境可按 DUT 语义改写。
package eth_rm_scb_example_pkg;
  import uvm_pkg::*;
  import eth_seg_types_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  `include "uvm_macros.svh"

  // 生命周期与业务预测分离：派生类只需覆写 model_predict；多 IP 各建一个本组件并设置 agent_name。
  class eth_rm_scb_example extends uvm_component;
    `uvm_component_utils(eth_rm_scb_example)
    string agent_name = "eth0";
    eth_seg_scoreboard sb;
    eth_base_seq rm_seq, scb_seq;
    eth_seg_sequencer sqr;
    uvm_analysis_imp#(eth_seg_reset_notice_t, eth_rm_scb_example) reset_export;
    bit sampling_ready, in_prediction;
    int unsigned predictions, outputs;

    protected process worker;
    protected bit subscribed, stopping;
    protected bit reset_seen[2], reset_asserted[2];
    protected int unsigned generation;

    function new(string name = "rm_scb", uvm_component parent = null);
      super.new(name, parent);
      reset_export = new("reset_export", this);
    endfunction

    // 只借用已有 agent，避免与 bind wrapper 重复拥有驱动权。
    function void build_phase(uvm_phase phase);
      super.build_phase(phase);
      sb = eth_seg_scoreboard::type_id::create("sb", this);
      rm_seq = eth_base_seq::type_id::create("rm_seq");
      scb_seq = eth_base_seq::type_id::create("scb_seq");
    endfunction

    // agent 已全部 build：按完整路径取 sqr，不依赖兄弟 connect 顺序；analysis 连接须在端口解析前完成。
    function void connect_phase(uvm_phase phase);
      uvm_component component_handle;
      super.connect_phase(phase);
      component_handle = uvm_root::get().find({agent_name, ".sequencer"});
      if (!$cast(sqr, component_handle) || sqr == null) begin
        `uvm_fatal("ETH_RM_SQR", {"missing Ethernet sequencer for ", agent_name})
        return;
      end
      if (sqr.monitor_hub == null) begin
        `uvm_fatal("ETH_RM_HUB", "agent did not publish its monitor hub during build")
        return;
      end
      sqr.monitor_hub.reset_ap.connect(reset_export);
    endfunction

    // 用 set_sequencer 关联采样对象，不调用会发送默认报文的 start()。
    function void end_of_elaboration_phase(uvm_phase phase);
      super.end_of_elaboration_phase(phase);
      if (sqr == null || eth_seg_sequencer::get_sqr(agent_name) != sqr) begin
        `uvm_fatal("ETH_RM_REGISTER", "agent sequencer registry is not ready")
        return;
      end
      rm_seq.set_sequencer(sqr);
      scb_seq.set_sequencer(sqr);
      subscribe_both();
    endfunction

    // 复位协调可重复调用，不会重复建立同编号订阅。
    protected function void subscribe_both();
      if (subscribed) return;
      rm_seq.subscribe(ETH_SEG_RX, 0);
      scb_seq.subscribe(ETH_SEG_TX, 0);
      subscribed = 1;
    endfunction

    protected function void cancel_workers();
      sampling_ready = 0;
      generation++;
      if (worker != null) worker.kill();
      in_prediction = 0;
      if (subscribed) begin
        rm_seq.unsubscribe(ETH_SEG_RX, 0);
        scb_seq.unsubscribe(ETH_SEG_TX, 0);
        subscribed = 0;
      end
    endfunction

    // 复位回调不能等待：任一方向断言即终止旧预测并清理出口期望/实际队列；
    // 新一代工作进程等两个方向复位都释放后才启动。
    function void write(eth_seg_reset_notice_t notice);
      reset_seen[notice.direction] = 1;
      reset_asserted[notice.direction] = notice.asserted;
      if (notice.asserted) begin
        cancel_workers();
        sb.flush_direction(ETH_SEG_TX);
        predictions = 0;
        outputs = 0;
      end
    endfunction

    // 默认字节透传，输入已是完整帧；派生任务可消耗仿真时间，返回 null 表示预期丢包。
    virtual task model_predict(input eth_seg_seq_item input_pkt,
                               output eth_seg_seq_item expected_pkt);
      expected_pkt = eth_seg_seq_item::type_id::create("expected");
      expected_pkt.copy(input_pkt);
      expected_pkt.direction = ETH_SEG_TX;
    endtask

    // 仅非空期望写入 SCB；统计按复位 epoch 重新开始。
    protected task sample_inputs();
      forever begin
        eth_seg_seq_item input_pkt, expected_pkt;
        rm_seq.mon_xaction(input_pkt, ETH_SEG_RX, 0);
        if (input_pkt == null) return;
        in_prediction = 1;
        model_predict(input_pkt, expected_pkt);
        if (expected_pkt != null) begin
          sb.write_before(expected_pkt);
          predictions++;
        end
        in_prediction = 0;
      end
    endtask

    // 独立于 RM 采样出口，实际包先到时由 SCB 缓存。
    protected task sample_outputs();
      forever begin
        eth_seg_seq_item actual_pkt;
        scb_seq.mon_xaction(actual_pkt, ETH_SEG_TX, 0);
        if (actual_pkt == null) return;
        sb.write_after(actual_pkt);
        outputs++;
      end
    endtask

    // 每代工作进程含两条消费子线程，一次 kill 同时终止阻塞获取与业务预测；
    // generation 防止同一时刻的复位与工作进程启动交错后重新置 ready。
    task run_phase(uvm_phase phase);
      forever begin
        int unsigned current_generation;
        wait (stopping || (reset_seen[0] && reset_seen[1] &&
                           !reset_asserted[0] && !reset_asserted[1]));
        if (stopping) return;
        subscribe_both();
        current_generation = generation;
        worker = null;
        fork
          begin
            if (!stopping && current_generation == generation) begin
              worker = process::self();
              sampling_ready = 1;
              fork
                sample_inputs();
                sample_outputs();
              join
            end
          end
        join_none
        wait (worker != null || generation != current_generation || stopping);
        wait (!sampling_ready || generation != current_generation || stopping);
        if (stopping) return;
      end
    endtask

    // 只表示本组件排空；还需核对收包/匹配数量及 DUT/driver/monitor 空闲。
    function bit is_idle();
      if (in_prediction || !sb.is_idle()) return 0;
      if (!subscribed) return 1;
      return sqr.monitor_hub.pending(ETH_SEG_RX) == 0 &&
             sqr.monitor_hub.pending(ETH_SEG_TX) == 0;
    endfunction

    // 在核对排空后调用；保留 SCB 残留检查，过早结束不会被当作复位清理。
    function void stop_sampling();
      stopping = 1;
      cancel_workers();
    endfunction
  endclass
endpackage
