// segmented agent：按 CLIENT/MAC 角色创建发送、接收和 ready 驱动，双向 monitor 始终存在。
// connect 时把 sequencer 发布到静态表（Tcl 按名字查找），final 时撤销；passive 也创建仅供采样的 sequencer。
class eth_seg_agent #(int RATE = 100) extends uvm_agent;
  `uvm_component_param_utils(eth_seg_agent#(RATE))

  eth_seg_config#(RATE) cfg;
  eth_seg_sequencer sequencer;
  eth_seg_monitor_hub monitor_hub;
  eth_seg_tx_driver#(RATE) tx_driver;
  eth_seg_rx_driver#(RATE) rx_driver;
  eth_seg_ready_driver#(RATE) ready_driver;
  eth_seg_tx_monitor#(RATE) tx_monitor;
  eth_seg_rx_monitor#(RATE) rx_monitor;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    string reason;
    super.build_phase(phase);
    if (cfg == null)
      void'(uvm_config_db#(eth_seg_config#(RATE))::get(this, "", "cfg", cfg));
    if (cfg == null) begin
      cfg = eth_seg_config#(RATE)::type_id::create("cfg");
      `uvm_fatal("ETH_AGENT_CFG", "eth_seg_agent requires cfg from parent or config_db")
    end
    if (!cfg.validate(reason)) `uvm_fatal("ETH_AGENT_CFG", reason)

    tx_monitor = eth_seg_tx_monitor#(RATE)::type_id::create("tx_monitor", this);
    rx_monitor = eth_seg_rx_monitor#(RATE)::type_id::create("rx_monitor", this);
    tx_monitor.cfg = cfg;
    rx_monitor.cfg = cfg;
    monitor_hub = eth_seg_monitor_hub::type_id::create("monitor_hub", this);
    sequencer = eth_seg_sequencer::type_id::create("sequencer", this);
    // 在 build 而非 connect 关联，兄弟 RM 在 connect 接入 reset_ap 时不依赖遍历顺序。
    sequencer.monitor_hub = monitor_hub;

    if (cfg.is_active == UVM_ACTIVE) begin
      case (cfg.role)
        ETH_SEG_CLIENT: begin
          tx_driver = eth_seg_tx_driver#(RATE)::type_id::create("tx_driver", this);
          tx_driver.cfg = cfg;
        end
        ETH_SEG_MAC: begin
          rx_driver = eth_seg_rx_driver#(RATE)::type_id::create("rx_driver", this);
          ready_driver = eth_seg_ready_driver#(RATE)::type_id::create("ready_driver", this);
          rx_driver.cfg = cfg;
          ready_driver.cfg = cfg;
        end
        default: `uvm_fatal("ETH_AGENT_ROLE", "unsupported eth_seg_config.role")
      endcase
    end
  endfunction

  function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    if (cfg != null && cfg.is_active == UVM_ACTIVE) begin
      if (cfg.role == ETH_SEG_CLIENT && tx_driver != null)
        tx_driver.seq_item_port.connect(sequencer.seq_item_export);
      else if (cfg.role == ETH_SEG_MAC && rx_driver != null)
        rx_driver.seq_item_port.connect(sequencer.seq_item_export);
    end
    tx_monitor.item_collected_port.connect(monitor_hub.sample_tx);
    rx_monitor.item_collected_port.connect(monitor_hub.sample_rx);
    tx_monitor.reset_state_port.connect(monitor_hub.reset_tx);
    rx_monitor.reset_state_port.connect(monitor_hub.reset_rx);
    sequencer.can_send = (tx_driver != null || rx_driver != null);
    eth_seg_sequencer::register_sqr(get_full_name(), sequencer);
  endfunction

  function void final_phase(uvm_phase phase);
    super.final_phase(phase);
    if (sequencer != null) eth_seg_sequencer::unregister_sqr(get_full_name(), sequencer);
  endfunction
endclass
