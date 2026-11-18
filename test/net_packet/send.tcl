# net_packet AIP Tcl 用例：参数按 AGENT_NAME 隔离，SV 独立比较线上报文；任何 Tcl 错误都必须让仿真失败。
source [file join $::env(AIP_CORE) dist aip_init.tcl]

# 每个命令核对独立 ack 和 status，避免超时旧结果被当作本次成功。
proc eth_net_cmd_ok {args} {
    uplevel #0 $args
    set ack [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$ack != $::_aip_cmd_seq || [aip_check_status] != 0} {
        error "ETH_NET_AIP_TCL_FAIL: $args: [aip_read_result]"
    }
}

eth_net_cmd_ok set_param path=eth1.tmpl value=ETH_IPV6_TCP
eth_net_cmd_ok set_param path=eth1.pkt_len value=128
eth_net_cmd_ok set_param path=eth1.outer_eth.dst_mac value=0xfedcba987654
eth_net_cmd_ok set_param path=eth2.tmpl value=ETH_IPV4_UDP_ROCEV2
eth_net_cmd_ok set_param path=eth2.pkt_len value=129
eth_net_cmd_ok set_param path=eth3.pkt_len value=512
eth_net_cmd_ok set_param path=eth3.outer_eth.dst_mac value=0x010203040506

# eth0 第一批使用默认 256B IPv4/UDP；随后同一 binary 内修改长度、MAC 和 payload。
eth_net_cmd_ok eth0_net_send count=2 rate_gbps=50 clk_freq_hz=415039062.5
eth_net_cmd_ok eth1_net_send count=3 rate_gbps=200 ifg_bytes=16
eth_net_cmd_ok eth2_net_send count=1 rate_gbps=400
eth_net_cmd_ok eth3_net_send count=4 mode=random_rate rate_min_gbps=25 rate_max_gbps=75
eth_net_cmd_ok set_param path=eth0.pkt_len value=64
eth_net_cmd_ok set_param path=eth0.outer_eth.dst_mac value=0x123456789abc
eth_net_cmd_ok set_param path=eth0.payload_byte value=0x5a
eth_net_cmd_ok eth0_net_send count=1
# RoCEv2 逐包递增：PSN 从 0xfffffe 跨 24 位回绕，WRITE_IMM 的 RETH VA 每包加 0x400；显式 payload_mode 保留。
eth_net_cmd_ok set_param path=eth2.pkt_len value=278
eth_net_cmd_ok set_param path=eth2.outer_rocev2.opcode value=RC_RDMA_WRITE_ONLY_IMM
eth_net_cmd_ok set_param path=eth2.outer_rocev2.dest_qp value=0x12
eth_net_cmd_ok set_param path=eth2.outer_rocev2.psn value=0xfffffe
eth_net_cmd_ok set_param path=eth2.outer_rocev2.reth_va value=0x10000
eth_net_cmd_ok set_param path=eth2.outer_rocev2.reth_r_key value=0x202
eth_net_cmd_ok set_param path=eth2.outer_rocev2.reth_dma_len value=200
eth_net_cmd_ok set_param path=eth2.outer_rocev2.imm_data value=0x1234abcd
eth_net_cmd_ok set_param path=eth2.payload_mode value=PAYLOAD_INCREMENT
eth_net_cmd_ok eth2_net_send count=3 rate_gbps=400 psn_step=1 va_step=0x400
puts "ETH_NET_AIP_TCL_COMPLETE"
eth_net_cmd_ok end_test
run
