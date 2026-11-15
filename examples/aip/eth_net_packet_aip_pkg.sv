// examples/aip 网络报文命令层：依赖 aip_core/update、net_packet_pkg 和 eth_flow_pkg。
// 先编译 AIP 再编译 net_packet_pkg，使 packet.load_params 能读取 Tcl 参数。
// sequence 拥有每次生成的 packet 和独立流控模型；静态 sqr 由 bind agent 拥有。
// Tcl 每次传入流控参数，不持久注册为 env 配置；此层不创建 env 或 agent。
package eth_net_packet_aip_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  import eth_flow_pkg::*;
  `include "uvm_macros.svh"

  // count/循环由 eth_base_seq 拥有，节流由 eth_flow_seq 负责；这里连接 Tcl 与业务内容。
  class eth_net_packet_aip_seq extends eth_flow_seq;
    `uvm_object_utils(eth_net_packet_aip_seq)

    // count 由 aip_cmd_seq 设置；默认生成一帧 256B IPv4/UDP 报文。
    function new(string name = "eth_net_packet_aip_seq");
      super.new(name);
    endfunction

    // 缺省参数沿用本次新对象默认值；显式实数必须完整解析且为有限正数。
    // 不用 atoi/int 中转，保留 415039062.5Hz 等小数频率，拒绝带尾随垃圾的输入。
    protected function bit read_real_arg(string args, string key, inout real value);
      string raw = aip_cmd::get_arg(args, key);
      string trailing;
      real parsed;

      if (raw == "") return 1;
      if ($sscanf(raw, "%f%s", parsed, trailing) != 1 || !(parsed > 0.0 && parsed <= 1.0e12)) begin
        `uvm_fatal("ETH_FLOW_ARG", {"invalid positive real argument: ", key, "=", raw})
        return 0;
      end
      value = parsed;
      return 1;
    endfunction

    // aip_cmd_seq 自动处理 count/time；本层按命令对象名读取其余本次参数。
    // 不重新加载 send config、不覆写 agent cfg；未知流控模式和非法 IFG 明确失败。
    virtual task body();
      aip_cmd command = aip_cmd::get_handle(get_name());
      string args, raw;

      if (command == null) begin
        `uvm_fatal("ETH_FLOW_COMMAND", "AIP flow sequence must be launched through its registered command")
        return;
      end
      args = command.args_in;
      if (!read_real_arg(args, "rate_gbps", rate_gbps) ||
          !read_real_arg(args, "clk_freq_hz", clk_freq_hz) ||
          !read_real_arg(args, "rate_min_gbps", rate_min_gbps) ||
          !read_real_arg(args, "rate_max_gbps", rate_max_gbps)) return;
      raw = aip_cmd::get_arg(args, "mode");
      if (raw != "" && raw != "fixed" && raw != "random_rate") begin
        `uvm_fatal("ETH_FLOW_ARG", "mode must be fixed or random_rate")
        return;
      end
      random_rate = (raw == "random_rate");
      raw = aip_cmd::get_arg(args, "ifg_bytes");
      if (raw != "") begin
        string trailing;
        if ($sscanf(raw, "%d%s", ifg_bytes, trailing) != 1) begin
          `uvm_fatal("ETH_FLOW_ARG", "ifg_bytes must be an integer")
          return;
        end
      end
      super.body();
    endtask

    // 每帧按实际 agent 名字读取协议模板、长度及协议头参数，保证多 IP 参数隔离。
    // pkt_len 不含前导/Ethernet FCS；负值/超长或容纳不下协议头时在打包前失败。
    // load_params 后显式 do_pack，避免修改字段后继续使用旧 raw_data。
    virtual function packet create_packet(int unsigned packet_index);
      eth_seg_sequencer sqr_handle = require_sqr(1);
      packet generated;
      string param_path;
      byte unsigned payload_byte;

      if (sqr_handle == null) return null;
      param_path = sqr_handle.get_parent().get_full_name();
      generated = new();
      generated.build_from_template(ETH_IPV4_UDP);
      generated.pkt_len = 256;
      generated.load_params(param_path);
      `aip_int(param_path, byte unsigned, payload_byte, 8'ha5)
      generated.payload_mode = PAYLOAD_FIXED;
      generated.payload_fixed_val = payload_byte;
      if (generated.pkt_len < 14 || generated.pkt_len > 16384 ||
          generated.pkt_len < generated.get_all_headers_length() + generated.get_all_trailers_length()) begin
        `uvm_fatal("ETH_NET_AIP_LENGTH", "pkt_len must be 14..16384 and contain the complete protocol stack")
        return null;
      end
      generated.do_pack();
      return generated;
    endfunction

    // 成功入队才报告活动；此通知不承担 Monitor 的物理完成语义。
    virtual function void packet_queued(int unsigned packet_index);
      aip_activity::tick();
    endfunction
  endclass

  // 查询表达式在 Tcl 命令执行时求值，必须在 UVM connect 完成后运行 bridge。
  // 用户只按自己的 AGENT_NAME 修改映射；同速率多个 IP 也各自拥有独立 sequencer。
  `aip_cmd_seq(eth0_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth0"))
  `aip_cmd_seq(eth1_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth1"))
  `aip_cmd_seq(eth2_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth2"))
  `aip_cmd_seq(eth3_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth3"))
endpackage
