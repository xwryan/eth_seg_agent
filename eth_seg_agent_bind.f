// eth_seg_agent 可选 add-on：bind wrapper eth_seg_bind_wrapper。
// 只在 bind 到已有 DUT 时加入，否则 wrapper 会成为多余顶层。
// 用大写 -F 引用（vcs -F <路径>/eth_seg_agent/eth_seg_agent_bind.f），路径相对本文件目录；不拉入依赖，前置每个写一行 -F，依次为 aip_core/aip_core.f flow_control/flow_control.f net_packet/net_packet.f eth_seg_agent/eth_seg_agent.f。
./bind/eth_seg_bind_wrapper.sv
