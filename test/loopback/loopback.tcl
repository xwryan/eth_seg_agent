# loopback Tcl 用例：set_param 开/关 lb0_mac.loopback（按帧在 TX EOP 读取），回环进行中再经 net_send 注入 RX；
# SV 独立核对哪些帧回到 RX 以及注入报文是否完整。
source [file join $::env(AIP_CORE) dist aip_init.tcl]

# 要求当前命令的独立 ack/status，不能把超时后的旧结果当作新命令成功。
proc lb_cmd_ok {args} {
    uplevel #0 $args
    set ack [aip_parse_int [get aip_core_pkg::__tcl_result_id]]
    if {$ack != $::_aip_cmd_seq || [aip_check_status] != 0} {
        error "ETH_LOOPBACK_TCL_FAIL: $args: [aip_read_result]"
    }
}

lb_cmd_ok set_param path=lb0_client.frame_length value=64
lb_cmd_ok set_param path=lb0_mac.loopback value=1
lb_cmd_ok lb0_send count=3
# 命令返回只表示帧已入 driver；推进仿真让本批帧在 TX 采样完成后再切换开关。
run 2us
lb_cmd_ok set_param path=lb0_mac.loopback value=0
lb_cmd_ok lb0_send count=2
run 2us
lb_cmd_ok set_param path=lb0_mac.loopback value=1
lb_cmd_ok lb0_send count=1
run 2us
# 回环进行中注入 3 个 128B IPv4/UDP：net_send 每批持锁，回环帧在队列等待后按序跟上；时钟频率取 RX 时钟。
lb_cmd_ok set_param path=lb0_mac.pkt_len value=128
lb_cmd_ok lb0_send count=4
lb_cmd_ok lb0_net_send count=3 rate_gbps=25 clk_freq_hz=166666666.67
run 3us
puts "ETH_LOOPBACK_TCL_COMPLETE"
lb_cmd_ok end_test
# end_test 的 ack 停在 UCLI；继续运行，SV 排空并正常结束 UVM。
run
