# VCS 构建入口：RATE 只是 smoke 回归的构建标签（接口同时实例化 100/200/400G）；各目标使用独立的 BUILD 目录。
.DEFAULT_GOAL := compile
VCS ?= vcs
RATE ?= 100
TEST ?= eth_seg_smoke_test
SEED ?= 1
BUILD ?= build/$(RATE)
SIMV := $(BUILD)/simv
UVM_HOME ?= $(VCS_HOME)/etc/uvm-1.2
# 外部依赖只用于相应的可选目标；普通 compile/run/bind-test 不需要它们。各仓库 filelist 用 *_ROOT 定位。
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
# 依赖 filelist 在前，本工程 eth_seg_agent.f 及可选部分在后，最后是测试/示例源码。
ETH_F := -f $(ETH_SEG_AGENT_ROOT)/eth_seg_agent.f
BIND_F := -f $(ETH_SEG_AGENT_ROOT)/eth_seg_agent_bind.f
NET_F := -f $(AIP_CORE_ROOT)/aip_core.f -f $(NET_PACKET_ROOT)/net_packet.f $(ETH_F) \
         -f $(ETH_SEG_AGENT_ROOT)/eth_seg_agent_net_packet.f
FLOW_F := -f $(AIP_CORE_ROOT)/aip_core.f -f $(NET_PACKET_ROOT)/net_packet.f -f $(FLOW_CONTROL_ROOT)/flow_control.f \
          $(ETH_F) -f $(ETH_SEG_AGENT_ROOT)/eth_seg_agent_net_packet.f -f $(ETH_SEG_AGENT_ROOT)/eth_seg_agent_flow.f
SRC := $(ETH_F) test/tb_top.sv test/eth_seg_smoke_test.sv
BIND_SRC := $(ETH_F) $(BIND_F) test/bind/eth_seg_bind_test_pkg.sv test/bind/tb_bind.sv
AIP_SRC := -f $(AIP_CORE_ROOT)/aip_core.f $(ETH_F) $(BIND_F) \
           examples/aip/eth_seg_aip_pkg.sv test/aip/eth_seg_aip_test_pkg.sv test/aip/tb_aip.sv
NET_TEST_SRC := $(NET_F) test/net_packet/eth_net_packet_test_pkg.sv test/net_packet/tb_net_packet.sv
FLOW_TEST_SRC := $(FLOW_F) test/net_packet/eth_net_packet_test_pkg.sv \
                 test/flow/eth_flow_test_pkg.sv test/flow/tb_flow.sv
NET_AIP_SRC := $(FLOW_F) $(BIND_F) \
               examples/aip/eth_net_packet_aip_pkg.sv test/net_packet/eth_net_packet_test_pkg.sv \
               test/net_packet/eth_net_packet_aip_test_pkg.sv test/net_packet/tb_net_packet_aip.sv
TIMING_SRC := $(ETH_F) test/timing/eth_timing_control.sv \
              test/timing/eth_timing_test_pkg.sv test/timing/tb_timing.sv
SCENARIO ?= all

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

# hub 契约测试不依赖 net_packet/AIP。
HUB_SRC := $(ETH_F) test/sampling/eth_seg_hub_test_pkg.sv test/sampling/tb_hub.sv

.PHONY: hub-test hub-run
hub-test:
	$(MAKE) --no-print-directory hub-run BUILD=build/sampling_hub

hub-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_hub $(HUB_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/hub.log
	python3 scripts/check_log.py $(BUILD)/logs/hub.log run ETH_HUB_TEST_COMPLETE


# RM/SCB 示例需要 net_packet；复位控制接口只属于测试。
SAMPLING_SRC := $(NET_F) \
                test/sampling/eth_sampling_control.sv examples/sampling/eth_rm_scb_example_pkg.sv \
                test/sampling/eth_rm_scb_test_pkg.sv test/sampling/tb_rm_scb.sv

.PHONY: sampling-test sampling-run
sampling-test:
	$(MAKE) --no-print-directory sampling-run BUILD=build/sampling

sampling-run:
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f"
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_rm_scb $(SAMPLING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/sampling.log
	python3 scripts/check_log.py $(BUILD)/logs/sampling.log run ETH_SAMPLING_TEST_COMPLETE

.PHONY: compile run regress clean bind-test bind-run aip-test aip-run \
        net-packet-test net-packet-run net-packet-aip-test net-packet-aip-run timing-test timing-run \
        timing-checker-test timing-checker-run

timing-checker-test:
	$(MAKE) --no-print-directory timing-checker-run BUILD=build/timing_checker

# 非法 X/Z 用例按精确诊断判通过，不能套用普通测试的零 error 规则。checker 随 eth_seg_agent.f 编译，故需 UVM。
timing-checker-run:
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
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_timing $(TIMING_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +SCENARIO=$(SCENARIO) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/timing_$(SCENARIO).log
	python3 scripts/check_log.py $(BUILD)/logs/timing_$(SCENARIO).log run ETH_TIMING_TEST_COMPLETE

net-packet-test:
	$(MAKE) --no-print-directory net-packet-run BUILD=build/net_packet

# net_packet 经其 net_packet.f 以 package 编译，测试只 import net_packet_pkg。
net-packet-run:
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f"
	test -n "$(NET_PACKET)" && test -f "$(NET_PACKET)/net_packet.f"
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
	test -n "$(AIP_CORE)" && test -f "$(AIP_CORE)/aip_core.f"
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -debug_access+all -top tb_aip $(AIP_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	AIP_CORE="$(AIP_CORE_ROOT)" $(SIMV) +ntb_random_seed=$(SEED) -ucli -do $(abspath test/aip/send.tcl) -no_save -exitstatus -l $(BUILD)/logs/aip_test.log < /dev/null
	python3 scripts/check_log.py $(BUILD)/logs/aip_test.log run ETH_AIP_TEST_COMPLETE

# 递归 make 覆盖 BUILD，避免 bind 和原 smoke 的编译缓存或 simv 相互覆盖。
bind-test:
	$(MAKE) --no-print-directory bind-run BUILD=build/bind

bind-run:
	mkdir -p $(BUILD)/logs $(BUILD)/csrc
	$(VCS) $(VCSFLAGS) -top tb_bind $(BIND_SRC) -l $(BUILD)/logs/compile.log
	python3 scripts/check_log.py $(BUILD)/logs/compile.log compile
	$(SIMV) +ntb_random_seed=$(SEED) -l $(BUILD)/logs/bind_test.log
	python3 scripts/check_log.py $(BUILD)/logs/bind_test.log run ETH_BIND_TEST_COMPLETE

compile:
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
