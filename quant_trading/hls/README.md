# Vitis HLS 参考内核

`fast_decoder_hls.cpp` 对应 PL FAST 状态机的四级流水：STEP/Tag96 检测、Pmap stop-bit 读取、字段边界与 7-bit 合并、Copy/Default/Increment/Delta/Constant 字段恢复；`order_book_hls.cpp` 对应 1024 槽 BRAM 订单字典、动态价格偏移量、成交查价、撤单和 10 档 bid/ask 更新。

两份代码使用与 RTL 相同的标准化记录字段，可在 Vitis HLS 中分别综合成替换 RTL 模块。HLS 内核中的静态 `field_op/uses_pmap/initial_value` 表对应交易所 FAST XML 模板，实际部署时由打包脚本生成。
