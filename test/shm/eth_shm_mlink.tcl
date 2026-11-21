# SHM 多链路用例的节点脚本（eth_shm_cases.yaml 的 eth_shm_mlink_node/eth_shm_mixed_node）：各链路的数据帧由 SV 测试同时收发，
# 控制通道是节点级的，与链路数无关。+shm_eth.hs=hello：dut_a（+shm_eth.self=0）发一次带数据的 hello，dut_b 等到后核对数据原样
# 到达；+shm_eth.hs=none：不用控制通道。与预期不符时打印 ETH_SHM_HS_FAIL（SimFlow 日志检查判失败），最后照常 end_test。
set ::aip_ack_timeout_ns 50000000
set self [aip_getparam shm_eth.self]
set mode [aip_getparam shm_eth.hs]
set payload {links=eth0,eth1,eth2,eth3 note={four data links, one control channel}}
set ::hs_ok 1

# 执行一条命令；状态须与 want_ok 一致，给了 want 时结果须完全相等。
proc hs {command want_ok {want ""}} {
    aip_send_cmd $command
    set status [aip_check_status]
    set result [aip_read_result]
    if {($status == 0) != $want_ok || ($want ne "" && $result ne $want)} {
        puts "ETH_SHM_HS_FAIL: $command -> status=$status result=$result"
        set ::hs_ok 0
    }
    return $result
}

if {$mode eq "hello" && $self == 0} {
    hs "eth_shm_signal name=hello data={$payload}" 1 {OK: eth_shm_signal: hello}
} elseif {$mode eq "hello" && $self == 1} {
    hs {eth_shm_wait name=hello timeout_ms=60000} 1 "OK: eth_shm_wait: $payload"
} elseif {$mode ne "none"} {
    puts "ETH_SHM_HS_FAIL: unknown +shm_eth.hs=$mode"
    set ::hs_ok 0
}
if {$::hs_ok && $mode ne "none"} {
    puts "ETH_SHM_HS_PASS self=$self mode=$mode"
}
end_test wait_done=1 timeout=5ms strict=1
run
