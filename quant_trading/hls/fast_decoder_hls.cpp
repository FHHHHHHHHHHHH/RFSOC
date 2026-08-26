#include <ap_int.h>
#include <hls_stream.h>

struct RawBeat { ap_uint<512> data; ap_uint<1> last; };
struct DecodedRecord {
  ap_uint<4> msg_type; ap_uint<4> side; ap_uint<8> security_id;
  ap_uint<32> timestamp; ap_uint<32> price; ap_uint<16> quantity;
  ap_uint<32> order_id;
};

enum FieldOperator { OP_DIRECT, OP_COPY, OP_DEFAULT, OP_INCREMENT,
                     OP_DELTA, OP_CONSTANT };

static ap_uint<64> stopbit_merge(const ap_uint<8> bytes[64], int &idx,
                                 ap_uint<7> &bits, bool &ok) {
  ap_uint<64> value = 0; bits = 0; ok = false;
  for (int n = 0; n < 9; ++n) {
#pragma HLS PIPELINE II=1
    if (idx >= 64) break;
    ap_uint<8> b = bytes[idx++];
    value = (value << 7) | b.range(6, 0); bits += 7;
    if (b[7]) { ok = true; break; }
  }
  return value;
}

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
  // Replace these constants from the exchange XML template during packaging.
  static const ap_uint<3> field_op[7] = {
    OP_DIRECT, OP_DIRECT, OP_DIRECT, OP_DIRECT,
    OP_DIRECT, OP_DIRECT, OP_DIRECT
  };
  static const bool uses_pmap[7] = {true,true,true,true,true,true,true};
  static const ap_uint<32> initial_value[7] = {0,0,0,0,0,0,0};
  static ap_uint<32> previous[7] = {0,0,0,0,0,0,0};
#pragma HLS ARRAY_PARTITION variable=field_op complete
#pragma HLS ARRAY_PARTITION variable=uses_pmap complete
#pragma HLS ARRAY_PARTITION variable=initial_value complete
#pragma HLS ARRAY_PARTITION variable=previous complete

  while (true) {
    if (in.empty()) continue;
    RawBeat beat = in.read(); ap_uint<8> bytes[64];
#pragma HLS ARRAY_PARTITION variable=bytes complete
    for (int b = 0; b < 64; ++b)
      bytes[b] = beat.data.range(b * 8 + 7, b * 8);

    int idx = 0; bool envelope = false;
    // STEP Tag95 is recognized while scanning; Tag96 starts the FAST body.
    for (int b = 0; b < 62; ++b) {
      if (bytes[b] == '9' && bytes[b + 1] == '6' && bytes[b + 2] == '=') {
        idx = b + 3; envelope = true; break;
      }
    }
    if (!envelope || idx >= 64) continue;

    ap_uint<7> pmap_bits = 0; bool pmap_ok = false;
    ap_uint<64> pmap = stopbit_merge(bytes, idx, pmap_bits, pmap_ok);
    if (!pmap_ok) continue;

    ap_uint<32> value[7];
#pragma HLS ARRAY_PARTITION variable=value complete
    ap_uint<6> pmap_index = 0; bool message_ok = true;
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
        ap_uint<7> entity_bits; bool entity_ok;
        ap_uint<64> encoded = stopbit_merge(bytes, idx, entity_bits, entity_ok);
        if (!entity_ok) { message_ok = false; break; }
        if (field_op[f] == OP_DELTA)
          restored = previous[f] + sign_extend(encoded, entity_bits);
        else
          restored = encoded;
        previous[f] = restored.range(31, 0);
      } else if (field_op[f] == OP_COPY) {
        restored = previous[f];
      } else if (field_op[f] == OP_INCREMENT) {
        restored = previous[f] + 1; previous[f] = restored.range(31, 0);
      } else {
        restored = initial_value[f];
      }
      value[f] = restored.range(31, 0);
    }
    if (!message_ok) continue;

    DecodedRecord r;
    r.msg_type=value[0].range(3,0); r.side=value[1].range(3,0);
    r.security_id=value[2].range(7,0); r.timestamp=value[3];
    r.price=value[4]; r.quantity=value[5].range(15,0); r.order_id=value[6];
    out.write(r);
  }
}
