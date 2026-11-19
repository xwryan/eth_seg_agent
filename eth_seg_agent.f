// ${ETH_SEG_AGENT_ROOT}，前置：aip_core.f（cfg 用 aip_core 宏读参；aip_core 要求 -timescale=1ns/1ps）
+incdir+${ETH_SEG_AGENT_ROOT}/src
+incdir+${ETH_SEG_AGENT_ROOT}/rtl
+incdir+${ETH_SEG_AGENT_ROOT}/seq_lib
${ETH_SEG_AGENT_ROOT}/rtl/eth_seg_if.sv
${ETH_SEG_AGENT_ROOT}/src/eth_seg_types.sv
${ETH_SEG_AGENT_ROOT}/src/eth_seg_pkg.sv
${ETH_SEG_AGENT_ROOT}/checker/eth_seg_protocol_checker.sv
