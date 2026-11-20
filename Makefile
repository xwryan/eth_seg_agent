# VCS 构建入口：RATE 只是 smoke 回归的构建标签（接口同时实例化 100/200/400G）；各目标使用独立的 BUILD 目录。
.DEFAULT_GOAL := compile
VCS ?= vcs
RATE ?= 100
TEST ?= eth_seg_smoke_test
SEED ?= 1
BUILD ?= build/$(RATE)
SIMV := $(BUILD)/simv
UVM_HOME ?= $(VCS_HOME)/etc/uvm-1.2
# aip_core、flow_control、net_packet 是全部目标的前置：cfg 用 aip_core 宏读参，eth_seg_agent.f 含 net_packet 报文序列与 flow 线速序列。
# 各仓库用 *_ROOT 定位；filelist 内部路径相对各自目录（大写 -F）。
AIP_CORE ?= $(AIP_CORE_ROOT)
NET_PACKET ?= $(NET_PACKET_ROOT)
FLOW_CONTROL ?= $(FLOW_CONTROL_ROOT)
export AIP_CORE_ROOT := $(abspath $(AIP_CORE))
export NET_PACKET_ROOT := $(abspath $(NET_PACKET))
export FLOW_CONTROL_ROOT := $(abspath $(FLOW_CONTROL))
export ETH_SEG_AGENT_ROOT := $(CURDIR)
FLOW_CLOCK_HZ ?= 415039062.5
INC := +incdir+test +incdir+$(UVM_HOME)/src
VCSFLAGS := -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -Mdir=$(BUILD)/csrc -o $(SIMV) +define+ETH_SEG_BUILD_RATE=$(RATE) $(INC)
# 每个项目一行大写 -F：依赖在前（aip_core.f 最先且只编译一次），本工程主 filelist eth_seg_agent.f（含 net_packet 报文序列与
# flow 线速序列）在后，可选 add-on eth_seg_agent_bind.f 只给 bind 的目标，最后是测试/示例源码。
ETH_F := -F $(AIP_CORE_ROOT)/aip_core.f -F $(FLOW_CONTROL_ROOT)/flow_control.f -F $(NET_PACKET_ROOT)/net_packet.f \
         -F $(ETH_SEG_AGENT_ROOT)/eth_seg_agent.f
BIND_F := -F $(ETH_SEG_AGENT_ROOT)/eth_seg_agent_bind.f
SRC := $(ETH_F) test/tb_top.sv test/eth_seg_smoke_test.sv
BIND_SRC := $(ETH_F) $(BIND_F) test/bind/eth_seg_bind_test_pkg.sv test/bind/tb_bind.sv
AIP_SRC := $(ETH_F) $(BIND_F) \
           examples/aip/eth_seg_aip_pkg.sv test/aip/eth_seg_aip_test_pkg.sv test/aip/tb_aip.sv
NET_TEST_SRC := $(ETH_F) test/net_packet/eth_net_packet_test_pkg.sv test/net_packet/tb_net_packet.sv
FLOW_TEST_SRC := $(ETH_F) test/net_packet/eth_net_packet_test_pkg.sv \
                 test/flow/eth_flow_test_pkg.sv test/flow/tb_flow.sv
NET_AIP_SRC := $(ETH_F) $(BIND_F) \
               examples/aip/eth_net_packet_aip_pkg.sv test/net_packet/eth_net_packet_test_pkg.sv \
               test/net_packet/eth_net_packet_aip_test_pkg.sv test/net_packet/tb_net_packet_aip.sv
TIMING_SRC := $(ETH_F) test/timing/eth_timing_control.sv \
              test/timing/eth_timing_test_pkg.sv test/timing/tb_timing.sv
SCENARIO ?= all
# 每个目标先确认三个前置项目的主 filelist 存在（eth_seg_agent.f 需要 flow_control 与 net_packet）。
CHECK_AIP := test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f" && \
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f" && \
	test -n "$(FLOW_CONTROL)" && test -f "$(FLOW_CONTROL)/flow_control.f"

.PHONY: flow-test flow-run
flow-test:
	$(MAKE) --no-print-directory flow-run BUILD=build/flow

flow-run:
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f"
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f"
	test -n "$(FLOW_CONTROL)" && test -f "$(FLOW_CONTROL)/flow_control.f"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_flow $(FLOW_TEST_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) +FLOW_CLOCK_HZ=$(FLOW_CLOCK_HZ) -l $(BUILD)/logs/flow_test.log
	python3 scripts/check_log.py $(BUILD)/logs/flow_test.log run ETH_FLOW_TEST_COMPLETE

# hub 契约测试只用 eth_seg_agent 的采样接口（编译仍需 eth_seg_agent.f 的全部前置）。
HUB_SRC := $(ETH_F) test/sampling/eth_seg_hub_test_pkg.sv test/sampling/tb_hub.sv

.PHONY: hub-test hub-run
hub-test:
	$(MAKE) --no-print-directory hub-run BUILD=build/sampling_hub

hub-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_hub $(HUB_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/hub.log
	python3 scripts/check_log.py $(BUILD)/logs/hub.log run ETH_HUB_TEST_COMPLETE


# RM/SCB 示例需要 net_packet；复位控制接口只属于测试。
SAMPLING_SRC := $(ETH_F) \
                test/sampling/eth_sampling_control.sv examples/sampling/eth_rm_scb_example_pkg.sv \
                test/sampling/eth_rm_scb_test_pkg.sv test/sampling/tb_rm_scb.sv

.PHONY: sampling-test sampling-run
sampling-test:
	$(MAKE) --no-print-directory sampling-run BUILD=build/sampling

sampling-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_rm_scb $(SAMPLING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/sampling.log
	python3 scripts/check_log.py $(BUILD)/logs/sampling.log run ETH_SAMPLING_TEST_COMPLETE

.PHONY: compile run regress clean bind-test bind-run aip-test aip-run \
        net-packet-test net-packet-run net-packet-aip-test net-packet-aip-run timing-test timing-run \
        timing-checker-test timing-checker-run loopback-test loopback-run loopback-aip-test loopback-aip-run

timing-checker-test:
	$(MAKE) --no-print-directory timing-checker-run BUILD=build/timing_checker

# 非法 X/Z 用例按精确诊断判通过，不能套用普通测试的零 error 规则。checker 随 eth_seg_agent.f 编译，故需 UVM 与其全部前置。
timing-checker-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps -top tb_timing_checker -Mdir=$(BUILD)/csrc -o $(SIMV) $(ETH_F) test/timing/tb_timing_checker.sv -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	@for scenario in rx_invalid rx_z rx_dontcare rx_eop_x rx_data_x tx_dontcare tx_data_x; do \
		$(SIMV) +CASE=$$scenario -l $(BUILD)/logs/$$scenario.log; \
		python3 scripts/check_timing_checker.py $(BUILD)/logs/$$scenario.log $$scenario || exit $$?; \
	done

timing-test:
	$(MAKE) --no-print-directory timing-run BUILD=build/timing

# SCENARIO 可单独选择 ready/gap/load/random_load/reset；默认运行全部阶段。
timing-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_timing $(TIMING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +SCENARIO=$(SCENARIO) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/timing_$(SCENARIO).log
	python3 scripts/check_log.py $(BUILD)/logs/timing_$(SCENARIO).log run ETH_TIMING_TEST_COMPLETE

net-packet-test:
	$(MAKE) --no-print-directory net-packet-run BUILD=build/net_packet

# net_packet 经其 net_packet.f 以 package 编译（eth_seg_agent.f 的前置），测试只 import net_packet_pkg。
net-packet-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_net_packet $(NET_TEST_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/net_packet_test.log
	python3 scripts/check_log.py $(BUILD)/logs/net_packet_test.log run ETH_NET_TEST_COMPLETE

net-packet-aip-test:
	$(MAKE) --no-print-directory net-packet-aip-run BUILD=build/net_packet_aip

net-packet-aip-run:
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f"
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f"
	test -n "$(FLOW_CONTROL)" && test -f "$(FLOW_CONTROL)/flow_control.f"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -debug_access+all -top tb_net_packet_aip $(NET_AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(AIP_CORE_ROOT)" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/net_packet/send.tcl) -no_save -exitstatus -l $(BUILD)/logs/net_packet_aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/net_packet_aip_test.log run ETH_NET_AIP_TEST_COMPLETE

aip-test:
	$(MAKE) --no-print-directory aip-run BUILD=build/aip

# AIP_CORE 指向 aip_core 源码；不会自动下载或修改用户的 AIP 仓库。
aip-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -debug_access+all -top tb_aip $(AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(AIP_CORE_ROOT)" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/aip/send.tcl) -no_save -exitstatus -l $(BUILD)/logs/aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/aip_test.log run ETH_AIP_TEST_COMPLETE

# loopback：CLIENT 代替 DUT 发 TX，MAC 开 loopback 回灌 RX；plusarg 同时覆盖读参开关、构建期枚举与 build 拒绝。
LOOPBACK_SRC := $(ETH_F) $(BIND_F) test/loopback/eth_loopback_link.sv \
                test/loopback/eth_seg_loopback_test_pkg.sv test/loopback/tb_loopback.sv
LOOPBACK_AIP_SRC := $(ETH_F) $(BIND_F) examples/aip/eth_seg_aip_pkg.sv examples/aip/eth_net_packet_aip_pkg.sv \
                    test/loopback/eth_loopback_link.sv test/loopback/eth_seg_loopback_test_pkg.sv \
                    test/loopback/eth_seg_loopback_aip_test_pkg.sv test/loopback/tb_loopback_aip.sv
LOOPBACK_ARGS := +lbp_mac.loopback=1 +lbo_mac.loopback=1 +lbo_mac.max_pending=3 \
                 +lbf_mac.rx_valid_pattern=ETH_SEG_PERIODIC +lbf_mac.rx_valid_high_cycles=3 +lbf_mac.rx_valid_low_cycles=1 \
                 +lbn_client.loopback=1 +lbn_mac.role=ETH_SEG_MAC +lbn_mac.is_active=UVM_PASSIVE +lbn_mac.loopback=1

loopback-test:
	$(MAKE) --no-print-directory loopback-run BUILD=build/loopback

loopback-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_loopback $(LOOPBACK_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) $(LOOPBACK_ARGS) -l $(BUILD)/logs/loopback_test.log
	python3 scripts/check_log.py $(BUILD)/logs/loopback_test.log run ETH_LOOPBACK_TEST_COMPLETE

# 真实 UCLI/Tcl：set_param path=lb0_mac.loopback 运行期开关，并在回环中用 net_send 注入 RX（需 net_packet、flow_control）。
loopback-aip-test:
	$(MAKE) --no-print-directory loopback-aip-run BUILD=build/loopback_aip

loopback-aip-run:
	$(CHECK_AIP)
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f"
	test -n "$(FLOW_CONTROL)" && test -f "$(FLOW_CONTROL)/flow_control.f"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -debug_access+all -top tb_loopback_aip $(LOOPBACK_AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(AIP_CORE_ROOT)" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/loopback/loopback.tcl) -no_save -exitstatus -l $(BUILD)/logs/loopback_aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/loopback_aip_test.log run ETH_LOOPBACK_AIP_TEST_COMPLETE

# 递归 make 覆盖 BUILD，避免 bind 和原 smoke 的编译缓存或 simv 相互覆盖。
bind-test:
	$(MAKE) --no-print-directory bind-run BUILD=build/bind

bind-run:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_bind $(BIND_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/bind_test.log
	python3 scripts/check_log.py $(BUILD)/logs/bind_test.log run ETH_BIND_TEST_COMPLETE

compile:
	$(CHECK_AIP)
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) $(SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile

run: compile
	$(SIMV) +UVM_TESTNAME=$(TEST) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/$(TEST).log
	python3 scripts/check_log.py $(BUILD)/logs/$(TEST).log run

regress:
	@mkdir -p logs
	@set -e; for r in 100 200 400; do \
		$(MAKE) --no-print-directory run RATE=$$r SEED=$${SEED:-1} BUILD=build/$$r; \
	done
	@python3 scripts/check_log.py build/100/logs/$(TEST).log run
	@python3 scripts/check_log.py build/200/logs/$(TEST).log run
	@python3 scripts/check_log.py build/400/logs/$(TEST).log run

clean:
	rm -rf build logs
