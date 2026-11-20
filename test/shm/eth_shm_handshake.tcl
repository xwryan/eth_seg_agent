# SHM 带内握手用例的节点脚本（eth_shm_cases.yaml 的 eth_shm_hs_node），按 +shm_eth.self 分 dut_a（0）与 dut_b（1）：
#   +shm_eth.hs=round_trip：dut_a 先核对几条本地拒绝，再发 early、empty（空数据）与带数据的 hello，等 dut_b 的 reply（回显
#     hello 的数据）；dut_b 等 hello、回 reply，再取 early 与 empty（它们早于 hello 到达，已缓存）。数据含空格、逗号、等号
#     与嵌套花括号，须原样到达。最后两端交换 done_a/done_b：确认对端不再发帧后才 end_test（先结束的节点会关掉端口）。
#   +shm_eth.hs=no_signal：dut_b 不发 hello；dut_a 等 hello，eth_shm_wait 须在 3000ms（墙钟）后返回 ERROR。之后两端照样交换
#     done_a/done_b 再结束：dut_b 不能先结束关端口，否则 dut_a 还没发完的数据帧被 switch 丢弃（SHM_HEALTH_DROP）。
# 每步与预期不符时打印 ETH_SHM_HS_FAIL（SimFlow 日志检查判失败）并继续，最后照常 end_test；全部符合打印 ETH_SHM_HS_PASS。
set ::aip_ack_timeout_ns 50000000
set self [aip_getparam shm_eth.self]
set mode [aip_getparam shm_eth.hs]
set payload {qpn=0x10 psn=0x000100 opcode=RC_SEND_ONLY len=64 data=PATTERN pattern=0xde,0xad,0xbe {nested {braces} kept} dmac=0x020000000002 dst_ip=10.0.0.2}
set ::hs_ok 1

# 执行一条命令；状态须与 want_ok 一致，给了 want 时结果须完全相等（want_glob=1 时按 string match）。返回结果文本。
proc hs {command want_ok {want ""} {want_glob 0}} {
    aip_send_cmd $command
    set status [aip_check_status]
    set result [aip_read_result]
    set match [expr {$want eq "" || ($want_glob ? [string match $want $result] : $result eq $want)}]
    if {($status == 0) != $want_ok || !$match} {
        puts "ETH_SHM_HS_FAIL: $command -> status=$status result=$result"
        set ::hs_ok 0
    }
    return $result
}

if {$mode eq "round_trip" && $self == 0} {
    # 本地拒绝（不涉及对端）：缺名字、非法名字、未知键、非法超时，以及等一个对端不会发的信号（200ms 墙钟后超时）。
    hs {eth_shm_signal data=x} 0 {ERROR: eth_shm_signal: name='': needs 1..64 characters}
    hs {eth_shm_signal name=bad/name} 0 {ERROR: eth_shm_signal: name=bad/name: only letters, digits and _ . : - are allowed}
    hs {eth_shm_signal name=x color=red} 0 {ERROR: eth_shm_signal: unknown argument(s) color; allowed: data, name, wait}
    hs {eth_shm_signal name=x name=y} 0 {ERROR: eth_shm_signal: name= is given more than once}
    hs {eth_shm_wait name=x timeout_ms=0} 0 {ERROR: eth_shm_wait: timeout_ms must be a positive number of milliseconds}
    hs {eth_shm_wait name=x timeout_ms=abc} 0 {ERROR: eth_shm_wait: timeout_ms=abc: not an unsigned integer literal}
    hs {eth_shm_wait name=nobody timeout_ms=200} 0 \
        {ERROR: eth_shm_wait: no 'nobody' signal from the peer within 200 ms (wall clock; local time advanced *} 1
    # early/empty 先于 hello 发出，dut_b 等完 hello 才取它们：信号先到先缓存。
    hs {eth_shm_signal name=early data={early bird}} 1 {OK: eth_shm_signal: early}
    hs {eth_shm_signal name=empty} 1 {OK: eth_shm_signal: empty}
    hs "eth_shm_signal name=hello data={$payload}" 1 {OK: eth_shm_signal: hello}
    hs {eth_shm_wait name=reply timeout_ms=60000} 1 "OK: eth_shm_wait: echo $payload"
    hs {eth_shm_signal name=done_a} 1 {OK: eth_shm_signal: done_a}
    hs {eth_shm_wait name=done_b timeout_ms=60000} 1 {OK: eth_shm_wait: }
} elseif {$mode eq "round_trip" && $self == 1} {
    hs {eth_shm_wait name=hello timeout_ms=60000} 1 "OK: eth_shm_wait: $payload"
    hs "eth_shm_signal name=reply data={echo $payload}" 1 {OK: eth_shm_signal: reply}
    hs {eth_shm_wait name=early timeout_ms=60000} 1 {OK: eth_shm_wait: early bird}
    hs {eth_shm_wait name=empty timeout_ms=60000} 1 {OK: eth_shm_wait: }
    hs {eth_shm_signal name=done_b} 1 {OK: eth_shm_signal: done_b}
    hs {eth_shm_wait name=done_a timeout_ms=60000} 1 {OK: eth_shm_wait: }
} elseif {$mode eq "no_signal" && $self == 0} {
    hs {eth_shm_wait name=hello timeout_ms=3000} 1
    hs {eth_shm_signal name=done_a} 1 {OK: eth_shm_signal: done_a}
    hs {eth_shm_wait name=done_b timeout_ms=60000} 1 {OK: eth_shm_wait: }
} elseif {$mode eq "no_signal" && $self == 1} {
    hs {eth_shm_wait name=done_a timeout_ms=60000} 1 {OK: eth_shm_wait: }
    hs {eth_shm_signal name=done_b} 1 {OK: eth_shm_signal: done_b}
} else {
    puts "ETH_SHM_HS_FAIL: unknown +shm_eth.hs=$mode or +shm_eth.self=$self"
    set ::hs_ok 0
}
if {$::hs_ok} {
    puts "ETH_SHM_HS_PASS self=$self mode=$mode"
}
end_test wait_done=1 timeout=5ms strict=1
run
