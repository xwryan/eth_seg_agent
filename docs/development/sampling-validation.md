# 整包采样与批量发包验证记录

日期：2026-10-30。
本次交付扩展 eth_base_seq、agent 的整包订阅缓存及 SCB 直接写入接口，配套可运行
RM/SCB 示例。使用方法见 [采样集成](../integration/sampling.md) 和
[net_packet 集成](../integration/net_packet.md)。

## 环境

VCS 为 `W-2024.09-SP1_Full64`，UVM 为 1.2，外部依赖 net_packet 与 aip_core 经各自 filelist 编译。
每轮使用不可变源码快照及独立目录构建，构建产物和原始日志不提交到仓库。
采样、bind、net_packet 和网络 AIP 路径在最终产品源码快照上重新验证；普通 AIP、smoke、timing 与
checker 结果来自较早快照：它们不调用本轮末次修改的阻塞采样方法，正常静态登记路径未变。
之后 hub 测试接收器只把 write 形参名与 UVM 基类统一为 t（消除 SV-ANDNMD 编译告警，产品源码未变）并复测。

## 验证结果

最终快照上五个目标及 net_packet 第二个随机种子全部通过；hub 告警修正后复测通过。

实际回归证据：

| 目标 | 种子 | 已通过结果 |
| --- | --- | --- |
| hub-test | 7 | 110 项检查，14 次预期诊断（9 fatal、5 error），形参名告警已消除 |
| sampling-test | 7 | 三速率合计 24 次匹配、3 次精确预期 mismatch；每速率丢弃一个半包并清理三类在途状态 |
| net-packet-test | 7、19 | 每种子 12 条链路、472 帧；13 次预期 fatal；analysis/seq 两条路径逐字节通过 |
| bind-test | 7 | 四实例各 8 TX + 8 RX，每实例三组 Monitor 和 passive 采样通过，12 个独立 sqr |
| net-packet-aip-test | 7 | 四个 IP 分别 3/3/1/4 帧；Tcl 重复命令/改参及持久采样通过 |
| aip-test | 7 | 四个命名 IP 分别匹配 3/3/1/4 帧；真实 Tcl 命令及参数隔离 |
| smoke | 7 | 同一仿真包含 100/200/400G；原格式、负载及错误帧自检通过 |
| timing-test | 7 | 三速率 × 两种前导设置，共 6 个 fixture 完成全部阶段 |
| timing-checker-test | 定向 | 7/7 场景按精确诊断通过 |

普通 UVM 回归要求完成标记、完整 summary 和零意外错误；上述 UVM 日志的最终
WARNING/ERROR/FATAL 均为 0。定向负向测试只捕获预期 ID/严重级别并核对次数。
checker 的四个非法输入场景各产生一个指定 VCS 原生 Error，另外三个合法场景零错误，
通过 `scripts/check_timing_checker.py` 判定，不能把这组日志描述为原生零错误。
hub 单元测试没有物理 interface 实例，编译时有 UII-L 提示；它只测试事务级逻辑，
该提示不影响测试。其它四个目标的编译无 Warning/Error/Fatal。

## 覆盖与证据对应

| 设计契约 | 验证方法 |
| --- | --- |
| 完整 EOP、字节序、FCS/前导及错误边带 | net_packet 三速率四格式，analysis 与 seq 各自比对独立原始字节期望；bind 检查 EOP 边带 |
| 单拍多包、跨周期、连续/周期/随机节奏 | 400G 默认格式额外 32 短包/方向，断言同拍包边界出现；其它格式与 timing 覆盖气泡及负载 |
| 独立订阅、无历史回放、多 IP、深拷贝 | hub 双订阅改写隔离与双实例；bind 四链路；AIP 四 IP 独立命令/参数 |
| 超时、取消、重订阅、读者死亡、并发读取 | hub 阻塞读取、旧槽取消和重新使用同编号、kill 后接管、精确错误诊断 |
| 容量/错误配置 | hub 验证零容量、重复订阅、未订阅、空事务、溢出；错误后已有队列保持 |
| 复位与等待同时发生 | hub 同时入包/复位，等待下一包；跨复位保留原 20ns 截止时间；重复通知抑制及 epoch |
| 三层在途状态同时复位 | sampling-test 让 RM 持有旧包、hub 留整包、Monitor 留半包，再复位并验证新批次 |
| passive 与静态表 | bind 观察者无 driver 但可取包；发送入口拒绝 passive；hub 检查重复登记不能覆盖及按拥有者撤销 |
| count 与生成方式 | net_packet 每方向各 3 次显式快照重放、默认生成、按索引生成；错误生成/count/type 不进入握手 |
| Tcl 生命周期 | 网络 AIP 同端口两次命令、运行时改参；持久采样对象累计消费并核对字节 |
| SCB 到达顺序和判错能力 | hub 直接写入测试；sampling-test 实际先到/期望先到窗口断言、故意坏字节、残留检查及方向清理 |

hub 的检查次数含逐字节断言，并非相同数量的独立测试场景。各目标的完成条件除包数
之外还检查相关队列、driver/Monitor、RM 和 SCB 状态；不以 finish_item 或空队列单独判定。

## 复现命令

加载 VCS 环境后在仓库根目录运行（依赖路径按实际环境替换；当前 Makefile 的全部目标都需 aip_core）：

```bash
export AIP_CORE_ROOT=/path/to/aip_core NET_PACKET_ROOT=/path/to/net_packet FLOW_CONTROL_ROOT=/path/to/flow_control
make hub-test SEED=7
make sampling-test SEED=7
make net-packet-test SEED=7
build/net_packet/simv +ntb_random_seed=19 -l build/net_packet/logs/net_packet_seed19.log
python3 scripts/check_log.py build/net_packet/logs/net_packet_seed19.log run ETH_NET_TEST_COMPLETE
make bind-test SEED=7
make net-packet-aip-test SEED=7
make aip-test SEED=7
make run RATE=100 BUILD=build/sampling_smoke SEED=7
make timing-test SEED=7
make timing-checker-test
```

第二个 net_packet 种子复用同一 simv，不重复编译；smoke 一次已包含三种速率。
Makefile 自动执行编译/运行日志检查。

## 开发过程中处理的问题与审查范围

首次 hub 红测因尚未定义 hub 类型而编译失败。首次实现编译发现
测试 helper 的 check 名字与 UVM 基类冲突，改为 ensure；同时以显式完成位替代
对 process.status() 的 wait。首轮实现通过 93 项检查及 12 次精确预期诊断。
bind 和批量发送未分别保留实现前的红测快照，后续以独立字节期望、负向诊断及
完整传输计数验证，不将此记录伪称为所有目标均经历独立红绿过程。

最终审查增加了唤醒后重新检查队列的循环：刚入队的包可能在同一仿真时刻被复位
删除，此时继续等新包，使用剩余 timeout，避免提前误报超时。静态登记的 fatal
后增加显式 return，防止测试捕获 fatal 后继续覆盖旧表项。

审查覆盖全部 src/seq_lib 实现、两个 AIP 适配、bind/interface、涉及的测试及 RM/SCB
示例，重点核对深拷贝、读者终止、旧槽隔离、复位通知顺序、batch 继承、raw_data
权威性、passive 能力以及中文接口说明。提交前检查文档链接、快照源码一致性和
`git diff --check`，并确认未暂存构建日志等无关文件。

这些测试使用 VIP、独立引脚刺激和响应壳，未运行用户 DUT 或厂商 F-Tile RTL。
SCB 当前按出口顺序比较，乱序匹配需要业务键；示例预测方法支持单输出或丢弃，
复制到多个出口的业务需要扩展消费流程。FCS 传输检查复用 codec CRC 计算，
不作为 CRC 算法的独立认证。
