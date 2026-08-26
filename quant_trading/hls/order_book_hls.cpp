#include <ap_int.h>
#include <hls_stream.h>

struct DecodedRecord { ap_uint<4> msg_type; ap_uint<4> side; ap_uint<8> security_id; ap_uint<32> timestamp; ap_uint<32> price; ap_uint<16> quantity; ap_uint<32> order_id; };
struct L2Snapshot { ap_uint<32> timestamp, trade_price, bid_price, ask_price, bid_qty, ask_qty; ap_uint<8> security_id; ap_uint<4> msg_type, side; };
struct OrderSlot { ap_uint<32> key; ap_uint<24> price_delta; ap_uint<16> qty; ap_uint<1> side, valid; };

static bool find_order(OrderSlot dict[1024], ap_uint<32> key, ap_uint<10> &idx) {
#pragma HLS INLINE
  ap_uint<10> base = key.range(9,0);
  for (int p=0; p<4; ++p) {
#pragma HLS UNROLL
    ap_uint<10> probe = base + p;
    if (dict[probe].valid && dict[probe].key == key) { idx=probe; return true; }
  }
  idx=base; return false;
}

static void remove_level(ap_uint<32> price[10], ap_uint<32> qty[10], int level) {
#pragma HLS INLINE
  for (int j=0; j<9; ++j) if (j>=level) { price[j]=price[j+1]; qty[j]=qty[j+1]; }
  price[9]=0; qty[9]=0;
}

void order_book_hls(hls::stream<DecodedRecord> &in,
                    hls::stream<L2Snapshot> &out,
                    ap_uint<32> price_offset) {
#pragma HLS INTERFACE axis port=in
#pragma HLS INTERFACE axis port=out
#pragma HLS INTERFACE s_axilite port=price_offset bundle=control
#pragma HLS INTERFACE ap_ctrl_hs port=return
  static OrderSlot dict[1024];
#pragma HLS RESOURCE variable=dict core=RAM_2P_BRAM
  static ap_uint<32> bid_price[10], ask_price[10], bid_qty[10], ask_qty[10];
#pragma HLS ARRAY_PARTITION variable=bid_price complete
#pragma HLS ARRAY_PARTITION variable=ask_price complete
#pragma HLS ARRAY_PARTITION variable=bid_qty complete
#pragma HLS ARRAY_PARTITION variable=ask_qty complete

  while (!in.empty()) {
#pragma HLS PIPELINE II=1
    DecodedRecord e=in.read(); ap_uint<10> idx; bool found=find_order(dict,e.order_id,idx);
    ap_uint<32> actual_price=found ? price_offset+dict[idx].price_delta : e.price;
    ap_uint<32> remove_qty=(e.msg_type==2 && found) ? dict[idx].qty : e.quantity;

    if (e.msg_type==1) {
      dict[idx].valid=1;dict[idx].key=e.order_id;dict[idx].price_delta=e.price-price_offset;dict[idx].qty=e.quantity;dict[idx].side=e.side[0];
      ap_uint<32> *prices=(e.side[0]==0)?bid_price:ask_price; ap_uint<32> *quantities=(e.side[0]==0)?bid_qty:ask_qty;
      int level=10; for(int j=0;j<10;j++) { if(prices[j]==e.price){level=j;break;} if(level==10 && quantities[j]==0)level=j; }
      if(level<10) { quantities[level]+=e.quantity; prices[level]=e.price; }
    } else if((e.msg_type==2 || e.msg_type==3) && found) {
      if(dict[idx].qty<=remove_qty) dict[idx].valid=0; else dict[idx].qty-=remove_qty;
      ap_uint<32> *prices=(dict[idx].side==0)?bid_price:ask_price; ap_uint<32> *quantities=(dict[idx].side==0)?bid_qty:ask_qty;
      for(int j=0;j<10;j++) if(prices[j]==actual_price) { quantities[j]=(quantities[j]>remove_qty)?quantities[j]-remove_qty:0; if(quantities[j]==0) remove_level(prices,quantities,j); }
    }
    L2Snapshot s; s.timestamp=e.timestamp;s.trade_price=(e.msg_type==3)?actual_price:0;s.bid_price=bid_price[0];s.ask_price=ask_price[0];s.bid_qty=bid_qty[0];s.ask_qty=ask_qty[0];s.security_id=e.security_id;s.msg_type=e.msg_type;s.side=e.side;out.write(s);
  }
}
