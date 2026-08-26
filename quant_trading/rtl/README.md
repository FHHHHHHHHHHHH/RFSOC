# RTL 数据格式和寄存器

标准逐笔记录（128 bit）：

`[127:96] order_id | [95:80] quantity | [79:48] price | [47:16] timestamp | [15:8] security_id | [7:4] side | [3:0] msg_type`

`msg_type=1` 为委托，`2` 为撤单，`3` 为成交；`side=0` 买，`1` 卖。

FAST 解码器 AXI-Lite：`0x00 control`、`0x04 frame_count`、`0x08 byte_count`、`0x0c error_count`、`0x10 step_length`；`0x20..0x38` 为 7 个字段初值。

`control[20:0]` 每 3 bit 配置字段操作符：0 Direct、1 Copy、2 Default、3 Increment、4 Delta、5 Constant；`control[30:24]` 指定字段是否消耗 Pmap 位。`control[31]` 写 1 可清前值字典。

订单簿 AXI-Lite：`0x00 control`、`0x04 event_count`、`0x08 collision_count`、`0x0c price_offset`、`0x10 last_trade_price`、`0x14 lookup_miss_count`。

订单簿快照 256 bit：`[215:184] timestamp`、`[183:152] trade_price`、`[151:120] ask_qty`、`[119:88] ask_price`、`[87:56] bid_qty`、`[55:24] bid_price`、`[23:16] security_id`、`[15:12] msg_type`、`[11:8] side`、`[7:0] flags/pad`。
