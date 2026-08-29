#include <ap_int.h>
#include <hls_stream.h>

// ============================================================
// fast_decoder_hls.cpp
// ------------------------------------------------------------
// 对应 RTL 模块：rtl/fast_decoder_ip.v
//
// 作用：把原始 FAST / STEP 报文解码成标准的 128-bit 订单记录，
//      供后续 order_book_engine_ip 使用。
//
// 处理链路：
//   FAST 原始字节流 --> stopbit_merge 解析 --> Pmap + field decode
//   --> DecodedRecord --> market_event_reorder --> order_book_engine_ip
//
// 这份 HLS 代码保留了 RTL 中的核心语义：
//  - 识别 96= / 95=...96= 包装格式
//  - 解析存在位图 pmap
//  - 按字段 op 还原值
//  - 维持 previous[] 历史值用于 Copy / Delta / Increment
// ============================================================

struct RawBeat {
  ap_uint<512> data;
  ap_uint<1> last;
};

struct DecodedRecord {
  ap_uint<4> msg_type;
  ap_uint<4> side;
  ap_uint<8> security_id;
  ap_uint<32> timestamp;
  ap_uint<32> price;
  ap_uint<16> quantity;
  ap_uint<32> order_id;
};

enum FieldOperator {
  OP_DIRECT,
  OP_COPY,
  OP_DEFAULT,
  OP_INCREMENT,
  OP_DELTA,
  OP_CONSTANT
};

// stopbit_merge:
// 作用与 RTL 中的 var_acc / var_len 逻辑相对应，按 7-bit stop-bit 编码
// 把连续多个字节恢复成一个字段值，同时记录位数和是否结束。
static ap_uint<64> stopbit_merge(const ap_uint<8> bytes[64], int &idx,
                                 ap_uint<7> &bits, bool &ok) {
  ap_uint<64> value = 0;
  bits = 0;
  ok = false;

  for (int n = 0; n < 9; ++n) {
#pragma HLS PIPELINE II=1
    if (idx >= 64) break;

    ap_uint<8> b = bytes[idx++];
    value = (value << 7) | b.range(6, 0);
    bits += 7;

    if (b[7]) {
      ok = true;
      break;
    }
  }

  return value;
}

// sign_extend:
// 对 stop-bit 编码后的值执行符号扩展，映射到 RTL 中的 decoded_val / merged_value
// 处理逻辑，保证 DELTA 值对负数场景成立。
static ap_int<64> sign_extend(ap_uint<64> value, ap_uint<7> bits) {
  ap_int<64> result = value;

  if (bits != 0 && bits < 64 && value[bits - 1]) {
    for (int i = 0; i < 64; ++i) {
#pragma HLS UNROLL
      if (i >= bits) result[i] = 1;
    }
  }

  return result;
}

void fast_decoder_hls(hls::stream<RawBeat> &in,
                      hls::stream<DecodedRecord> &out) {
#pragma HLS INTERFACE axis port=in
#pragma HLS INTERFACE axis port=out
#pragma HLS INTERFACE ap_ctrl_none port=return

  // 这些常量对应 RTL 中 control_reg 中的字段配置。
  // 真实项目中可从 exchange XML 模板或配置寄存器写入，
  // 这里先用固定值保持功能可用。
  static const ap_uint<3> field_op[7] = {
    OP_DIRECT, OP_DIRECT, OP_DIRECT, OP_DIRECT,
    OP_DIRECT, OP_DIRECT, OP_DIRECT
  };
  static const bool uses_pmap[7] = {true, true, true, true, true, true, true};
  static const ap_uint<32> initial_value[7] = {0, 0, 0, 0, 0, 0, 0};
  static ap_uint<32> previous[7] = {0, 0, 0, 0, 0, 0, 0};
#pragma HLS ARRAY_PARTITION variable=field_op complete
#pragma HLS ARRAY_PARTITION variable=uses_pmap complete
#pragma HLS ARRAY_PARTITION variable=initial_value complete
#pragma HLS ARRAY_PARTITION variable=previous complete

  while (true) {
    if (in.empty()) continue;

    RawBeat beat = in.read();
    ap_uint<8> bytes[64];
#pragma HLS ARRAY_PARTITION variable=bytes complete

    for (int b = 0; b < 64; ++b) {
      bytes[b] = beat.data.range(b * 8 + 7, b * 8);
    }

    // 这个阶段对应 RTL 的 ST_SCAN / ST_TAG9 / ST_TAG96 / ST_PMAP 状态。
    int idx = 0;
    bool envelope = false;
    for (int b = 0; b < 62; ++b) {
      if (bytes[b] == '9' && bytes[b + 1] == '6' && bytes[b + 2] == '=') {
        idx = b + 3;
        envelope = true;
        break;
      }
    }
    if (!envelope || idx >= 64) continue;

    ap_uint<7> pmap_bits = 0;
    bool pmap_ok = false;
    ap_uint<64> pmap = stopbit_merge(bytes, idx, pmap_bits, pmap_ok);
    if (!pmap_ok) continue;

    ap_uint<32> value[7];
#pragma HLS ARRAY_PARTITION variable=value complete

    ap_uint<6> pmap_index = 0;
    bool message_ok = true;

    for (int f = 0; f < 7; ++f) {
#pragma HLS PIPELINE II=1
      bool present = !uses_pmap[f];

      if (uses_pmap[f]) {
        present = pmap_index < pmap_bits ? pmap[pmap_bits - 1 - pmap_index] : false;
        ++pmap_index;
      }

      if (field_op[f] == OP_CONSTANT) present = false;

      ap_uint<64> restored = 0;
      if (present) {
        ap_uint<7> entity_bits;
        bool entity_ok;
        ap_uint<64> encoded = stopbit_merge(bytes, idx, entity_bits, entity_ok);
        if (!entity_ok) {
          message_ok = false;
          break;
        }

        if (field_op[f] == OP_DELTA) {
          restored = previous[f] + sign_extend(encoded, entity_bits);
        } else {
          restored = encoded;
        }
        previous[f] = restored.range(31, 0);
      } else if (field_op[f] == OP_COPY) {
        restored = previous[f];
      } else if (field_op[f] == OP_INCREMENT) {
        restored = previous[f] + 1;
        previous[f] = restored.range(31, 0);
      } else {
        restored = initial_value[f];
      }

      value[f] = restored.range(31, 0);
    }

    if (!message_ok) continue;

    // 最终输出格式与 rtl/fast_decoder_ip.v 中的 m_axis_decoded_tdata 对齐：
    // {order_id, quantity, price, timestamp, security_id, side, msg_type}
    DecodedRecord r;
    r.msg_type = value[0].range(3, 0);
    r.side = value[1].range(3, 0);
    r.security_id = value[2].range(7, 0);
    r.timestamp = value[3];
    r.price = value[4];
    r.quantity = value[5].range(15, 0);
    r.order_id = value[6];

    out.write(r);
  }
}
