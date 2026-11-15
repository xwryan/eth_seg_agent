// AIP Tcl 网络发包命令示例：每帧按 agent 名读取 net_packet 参数，经 eth_flow_seq 限速发送。
// 需先编译 aip_core 再编译 net_packet_pkg；sequence 持有每次生成的 packet 与流控模型，本层不创建 env/agent。
package eth_net_packet_aip_pkg;
  import uvm_pkg::*;
  import aip_core_pkg::*;
  import net_packet_pkg::*;
  import eth_seg_pkg::*;
  import eth_net_packet_pkg::*;
  import eth_flow_pkg::*;
  `include "uvm_macros.svh"

  class eth_net_packet_aip_seq extends eth_flow_seq;
    `uvm_object_utils(eth_net_packet_aip_seq)

    function new(string name = "eth_net_packet_aip_seq");
      super.new(name);
    endfunction

    // 不经 atoi/int 中转，以保留 415039062.5Hz 等小数；显式值必须完整解析为有限正数，缺省时保留对象默认值。
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

    // count/time 由 aip_cmd_seq 处理，其余参数按命令对象名读取；不覆写 agent cfg，未知流控模式和非法 IFG 直接失败。
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

    // 每帧按实际 agent 名读取模板、长度与协议头参数（多 IP 参数隔离）；pkt_len 不含前导/FCS，非法时在打包前失败。
    // load_params 后显式 do_pack，避免修改字段后仍使用旧 raw_data。
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

    virtual function void packet_queued(int unsigned packet_index);
      aip_activity::tick();
    endfunction
  endclass

  // get_sqr 在命令执行时求值，bridge 必须在 connect 完成后运行；用户按自己的 AGENT_NAME 增减这组映射。
  `aip_cmd_seq(eth0_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth0"))
  `aip_cmd_seq(eth1_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth1"))
  `aip_cmd_seq(eth2_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth2"))
  `aip_cmd_seq(eth3_net_send, eth_net_packet_aip_seq, eth_seg_sequencer::get_sqr("eth3"))
endpackage
