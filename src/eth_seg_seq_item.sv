// 以字节而非总线宽度表示报文，同一 sequence 可用于三种速率；frame_bytes 从 DA 开始，含配置要求的 FCS。
// 位置字段为 -1 表示未指定/未观察；注入字段与观察字段并存，以保留错误测试意图。
// gap_segments：EOP 后最少的有效 idle 段数（无效拍不计），与负载间隔取较大者。
class eth_seg_seq_item extends uvm_sequence_item;
  `uvm_object_utils(eth_seg_seq_item)

  rand byte unsigned frame_bytes[];
  bit fcs_present = 0, inject_fcs_error = 0, inject_error = 0, rx_fcs_error = 0;
  bit [1:0] rx_error = 0;
  bit [2:0] rx_status = 1;
  int start_segment = -1, eop_segment = -1, empty_bytes = 0, gap_segments = 0;
  eth_seg_dir_e direction = ETH_SEG_TX;
  bit fcs_checked = 0, fcs_ok = 0, aborted = 0;
  bit [31:0] fcs = 0;
  time start_time = 0, end_time = 0;

  function new(string name = "eth_seg_seq_item");
    super.new(name);
  endfunction

  virtual function void do_copy(uvm_object rhs);
    eth_seg_seq_item source;
    super.do_copy(rhs);
    if (!$cast(source, rhs)) `uvm_fatal("ETH_SEG_COPY", "source is not eth_seg_seq_item")
    frame_bytes = new[source.frame_bytes.size()];
    foreach (frame_bytes[i]) frame_bytes[i] = source.frame_bytes[i];
    fcs_present = source.fcs_present;
    inject_fcs_error = source.inject_fcs_error;
    inject_error = source.inject_error;
    rx_fcs_error = source.rx_fcs_error;
    rx_error = source.rx_error;
    rx_status = source.rx_status;
    start_segment = source.start_segment;
    eop_segment = source.eop_segment;
    empty_bytes = source.empty_bytes;
    gap_segments = source.gap_segments;
    direction = source.direction;
    fcs_checked = source.fcs_checked;
    fcs_ok = source.fcs_ok;
    aborted = source.aborted;
    fcs = source.fcs;
    start_time = source.start_time;
    end_time = source.end_time;
  endfunction

  // 不转储帧内容，避免日志被 payload 淹没。
  virtual function string convert2string();
    return $sformatf("dir=%s bytes=%0d sop=%0d eop=%0d empty=%0d fcs_present=%0b fcs_ok=%0b",
                     direction.name(), frame_bytes.size(), start_segment, eop_segment,
                     empty_bytes, fcs_present, fcs_ok);
  endfunction
endclass
