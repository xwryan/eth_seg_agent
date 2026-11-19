// 可选 AIP 接入示例：把 Ethernet frame sequence 注册为 Tcl 命令；本层不创建 agent/env（agent cfg 读参与 loopback 开关在核心 VIP）。
package eth_seg_aip_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import eth_seg_pkg::*;
  `include "uvm_macros.svh"

  // 参数按当前 sequencer 的父 agent 名隔离，每次执行时读取 Tcl override/plusarg，不修改 agent cfg。
  class eth_seg_aip_frame_seq extends eth_seg_base_seq;
    `uvm_object_utils(eth_seg_aip_frame_seq)
    int count = 1;

    function new(string name = "eth_seg_aip_frame_seq");
      super.new(name);
    endfunction

    // finish_item 只表示 driver 入队，物理完成由 monitor/scoreboard 判定。
    task body();
      eth_seg_sequencer sqr_handle;
      string param_path;
      int unsigned frame_length;
      if (!$cast(sqr_handle, get_sequencer()) || sqr_handle == null) begin
        `uvm_fatal("ETH_AIP_SQR", "named active sequencer is not registered")
        return;
      end
      if (!sqr_handle.can_send) begin
        `uvm_fatal("ETH_AIP_PASSIVE", "passive sequencer cannot send frames")
        return;
      end
      if (count <= 0) begin
        `uvm_fatal("ETH_AIP_COUNT", "count must be positive")
        return;
      end
      param_path = sqr_handle.get_parent().get_full_name();
      for (int unsigned n = 0; n < count; n++) begin
        eth_seg_seq_item item;
        `aip_int(param_path, int unsigned, frame_length, 256)
        if (frame_length < 9 || frame_length > 16384) begin
          `uvm_fatal("ETH_AIP_LENGTH", "frame_length must be 9..16384 bytes")
          return;
        end
        item = eth_seg_seq_item::type_id::create($sformatf("frame_%0d", n));
        make_frame(item, frame_length, n);
        start_item(item);
        finish_item(item);
        aip_activity::tick();
      end
    endtask
  endclass

  // 静态初始化时注册，get_sqr 在命令执行时（connect 之后）求值；用户按自己的 AGENT_NAME 增减映射。
  `aip_cmd_seq(eth0_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth0"))
  `aip_cmd_seq(eth1_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth1"))
  `aip_cmd_seq(eth2_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth2"))
  `aip_cmd_seq(eth3_send, eth_seg_aip_frame_seq, eth_seg_sequencer::get_sqr("eth3"))
endpackage
