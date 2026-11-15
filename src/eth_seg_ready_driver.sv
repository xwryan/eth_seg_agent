// MAC 端 TX ready 发生器：负沿按连续/周期/随机图样更新 ready，不读取 RX valid，也不影响 TX valid。
class eth_seg_ready_driver #(int RATE = 100) extends uvm_component;
  `uvm_component_param_utils(eth_seg_ready_driver#(RATE))
  eth_seg_config#(RATE) cfg;
  int cycle_count = 0;

  function new(string name, uvm_component parent); super.new(name, parent); endfunction

  function bit next_ready();
    int period;
    case (cfg.ready_pattern)
      ETH_SEG_CONTINUOUS: return 1;
      ETH_SEG_PERIODIC: begin period = cfg.ready_high_cycles + cfg.ready_low_cycles; return ((cycle_count % period) < cfg.ready_high_cycles); end
      default: return ($urandom_range(0,99) < cfg.ready_high_pct);
    endcase
  endfunction

  task run_phase(uvm_phase phase);
    string reason; if (cfg == null || !cfg.validate(reason)) `uvm_fatal("ETH_READY_CFG", reason)
    cfg.vif.claim_ready(get_full_name());
    forever begin
      @(negedge cfg.vif.i_clk_tx);
      if (!cfg.vif.i_tx_rst_n) begin cfg.vif.drv_ready <= 0; cycle_count = 0; end
      else begin cfg.vif.drv_ready <= next_ready(); cycle_count++; end
    end
  endtask

  // 置零后释放，避免 passive 或下一个 test 看到旧 ready。
  function void final_phase(uvm_phase phase);
    if (cfg != null && cfg.vif != null) begin cfg.vif.drv_ready = 0; cfg.vif.release_ready(); end
  endfunction
endclass
