`timescale 1ns/1ps
// Streaming L2 order-book engine. The local dictionary is an open-addressed
// 1024-entry BRAM-friendly table.  An external true-dual-port BRAM interface
// mirrors {valid, side, remaining_qty, order_id, price_delta} for PS/debug.
// BRAM_ADDR_WIDTH is the width of the Vivado BRAM interface (32 bits for
// blk_mem_gen).  Only the low HASH_BITS bits are used by the 1024-entry table.
module order_book_engine_ip #(parameter integer DECODED_WIDTH=128,parameter integer SNAPSHOT_WIDTH=256,parameter integer BRAM_ADDR_WIDTH=32,parameter integer BRAM_DATA_WIDTH=64)(
 input wire aclk,input wire aresetn,
 input wire [7:0] s_axi_ctrl_awaddr,input wire s_axi_ctrl_awvalid,output wire s_axi_ctrl_awready,input wire [31:0] s_axi_ctrl_wdata,input wire [3:0] s_axi_ctrl_wstrb,input wire s_axi_ctrl_wvalid,output wire s_axi_ctrl_wready,output wire [1:0] s_axi_ctrl_bresp,output wire s_axi_ctrl_bvalid,input wire s_axi_ctrl_bready,input wire [7:0] s_axi_ctrl_araddr,input wire s_axi_ctrl_arvalid,output wire s_axi_ctrl_arready,output wire [31:0] s_axi_ctrl_rdata,output wire [1:0] s_axi_ctrl_rresp,output wire s_axi_ctrl_rvalid,input wire s_axi_ctrl_rready,
 input wire [DECODED_WIDTH-1:0] s_axis_decoded_tdata,input wire s_axis_decoded_tvalid,output wire s_axis_decoded_tready,input wire s_axis_decoded_tlast,
 output reg [SNAPSHOT_WIDTH-1:0] m_axis_snapshot_tdata,output reg m_axis_snapshot_tvalid,input wire m_axis_snapshot_tready,output reg m_axis_snapshot_tlast,
 output wire bram_clk,output reg bram_en,output reg [BRAM_ADDR_WIDTH-1:0] bram_addr,output reg [BRAM_DATA_WIDTH-1:0] bram_wrdata,input wire [BRAM_DATA_WIDTH-1:0] bram_rddata,output reg [BRAM_DATA_WIDTH/8-1:0] bram_we
);
 localparam integer HASH_BITS=10,HASH_SIZE=1024,LEVELS=10;
 localparam [2:0] IDLE=0,PROBE_READ=1,PROBE_CHECK=2,APPLY=3,EMIT=4;
 (* ram_style="block" *) reg [31:0] dict_key[0:HASH_SIZE-1];
 (* ram_style="block" *) reg [23:0] dict_delta[0:HASH_SIZE-1];
 (* ram_style="block" *) reg [15:0] dict_qty[0:HASH_SIZE-1];
 reg dict_valid[0:HASH_SIZE-1];reg dict_side[0:HASH_SIZE-1];
 reg [31:0] bid_price[0:LEVELS-1],ask_price[0:LEVELS-1],bid_qty[0:LEVELS-1],ask_qty[0:LEVELS-1];
 reg [2:0] state;reg [9:0] probe_idx;reg [2:0] probe_count;reg lookup_found;reg [3:0] apply_rank;
 reg [31:0] rd_key;reg [23:0] rd_delta;reg [15:0] rd_qty;reg rd_valid,rd_side;
 reg [31:0] control_reg,event_count,collision_count,miss_count,offset_price,last_trade_price;reg [31:0] last_timestamp;reg [7:0] last_security;
 reg [31:0] cur_order,cur_price,cur_time,cur_qty;reg [15:0] cur_qty16;reg [7:0] cur_sec;reg [3:0] cur_side,cur_type;reg cur_last;
 reg [31:0] lookup_price,snap_trade,snap_bid_price,snap_ask_price,snap_bid_qty,snap_ask_qty,remove_qty;reg level_found;integer i,j;
 reg aw_hold,w_hold,b_hold,r_hold;reg [7:0] awaddr;reg [31:0] wdata,rdata;
 wire [31:0] in_order=s_axis_decoded_tdata[127:96];wire[15:0]in_qty=s_axis_decoded_tdata[95:80];wire[31:0]in_price=s_axis_decoded_tdata[79:48];wire[31:0]in_time=s_axis_decoded_tdata[47:16];wire[7:0]in_sec=s_axis_decoded_tdata[15:8];wire[3:0]in_side=s_axis_decoded_tdata[7:4];wire[3:0]in_type=s_axis_decoded_tdata[3:0];
 assign s_axi_ctrl_awready=!aw_hold&&!b_hold;assign s_axi_ctrl_wready=!w_hold&&!b_hold;assign s_axi_ctrl_bresp=0;assign s_axi_ctrl_bvalid=b_hold;assign s_axi_ctrl_arready=!r_hold;assign s_axi_ctrl_rdata=rdata;assign s_axi_ctrl_rresp=0;assign s_axi_ctrl_rvalid=r_hold;
 assign s_axis_decoded_tready=(state==IDLE)&&(!m_axis_snapshot_tvalid||m_axis_snapshot_tready);
 assign bram_clk=aclk;
 initial begin
  for(i=0;i<HASH_SIZE;i=i+1)begin dict_valid[i]=0;dict_key[i]=0;dict_delta[i]=0;dict_qty[i]=0;dict_side[i]=0;end
 end
 always @(posedge aclk)begin
  if(!aresetn)begin
   state<=IDLE;probe_idx<=0;probe_count<=0;lookup_found<=0;apply_rank<=0;level_found<=0;rd_key<=0;rd_delta<=0;rd_qty<=0;rd_valid<=0;rd_side<=0;control_reg<=0;event_count<=0;collision_count<=0;miss_count<=0;offset_price<=100;last_trade_price<=0;last_timestamp<=0;last_security<=0;
   cur_order<=0;cur_price<=0;cur_time<=0;cur_qty<=0;cur_qty16<=0;cur_sec<=0;cur_side<=0;cur_type<=0;cur_last<=0;lookup_price<=0;snap_trade<=0;snap_bid_price<=0;snap_ask_price<=0;snap_bid_qty<=0;snap_ask_qty<=0;remove_qty<=0;
   m_axis_snapshot_tdata<=0;m_axis_snapshot_tvalid<=0;m_axis_snapshot_tlast<=0;aw_hold<=0;w_hold<=0;b_hold<=0;r_hold<=0;awaddr<=0;wdata<=0;rdata<=0;bram_en<=0;bram_addr<=0;bram_wrdata<=0;bram_we<=0;
   for(j=0;j<LEVELS;j=j+1)begin bid_price[j]<=0;ask_price[j]<=0;bid_qty[j]<=0;ask_qty[j]<=0;end
  end else begin
   bram_en<=0;bram_we<=0;
   if(s_axi_ctrl_awvalid&&s_axi_ctrl_awready)begin aw_hold<=1;awaddr<=s_axi_ctrl_awaddr;end
   if(s_axi_ctrl_wvalid&&s_axi_ctrl_wready)begin w_hold<=1;wdata<=s_axi_ctrl_wdata;end
   if(aw_hold&&w_hold&&!b_hold)begin if(awaddr[7:2]==0)control_reg<=wdata;else if(awaddr[7:2]==3)offset_price<=wdata;aw_hold<=0;w_hold<=0;b_hold<=1;end
   if(b_hold&&s_axi_ctrl_bready)b_hold<=0;
   if(s_axi_ctrl_arvalid&&s_axi_ctrl_arready)begin case(s_axi_ctrl_araddr[7:2])0:rdata<=control_reg;1:rdata<=event_count;2:rdata<=collision_count;3:rdata<=offset_price;4:rdata<=last_trade_price;5:rdata<=miss_count;default:rdata<=32'h4f424b34;endcase r_hold<=1;end
   if(r_hold&&s_axi_ctrl_rready)r_hold<=0;
   if(m_axis_snapshot_tvalid&&m_axis_snapshot_tready)m_axis_snapshot_tvalid<=0;
   case(state)
    IDLE:begin
     if(s_axis_decoded_tvalid&&s_axis_decoded_tready)begin
      cur_order<=in_order;cur_price<=in_price;cur_time<=in_time;cur_qty<=in_qty;cur_qty16<=in_qty;cur_sec<=in_sec;cur_side<=in_side;cur_type<=in_type;cur_last<=s_axis_decoded_tlast;
      probe_idx<=in_order[HASH_BITS-1:0];probe_count<=0;lookup_found<=0;lookup_price<=in_price;state<=PROBE_READ;
     end
    end
    PROBE_READ:begin rd_valid<=dict_valid[probe_idx];rd_key<=dict_key[probe_idx];rd_delta<=dict_delta[probe_idx];rd_qty<=dict_qty[probe_idx];rd_side<=dict_side[probe_idx];state<=PROBE_CHECK;end
    PROBE_CHECK:begin
     if(rd_valid&&rd_key==cur_order)begin lookup_found<=1;lookup_price<=offset_price+rd_delta;state<=APPLY;end
     else if(!rd_valid&&cur_type==4'd1)begin lookup_found<=1;lookup_price<=cur_price;dict_valid[probe_idx]<=1;dict_key[probe_idx]<=cur_order;dict_delta[probe_idx]<=cur_price-offset_price;dict_qty[probe_idx]<=cur_qty16;dict_side[probe_idx]<=cur_side[0];state<=APPLY;end
     else if(probe_count==3)begin lookup_found<=0;miss_count<=miss_count+1;state<=APPLY;end
     else begin probe_idx<=probe_idx+1;probe_count<=probe_count+1;collision_count<=collision_count+1;state<=PROBE_READ;end
    end
    APPLY:begin
     snap_trade<=last_trade_price;snap_bid_price<=bid_price[0];snap_ask_price<=ask_price[0];snap_bid_qty<=bid_qty[0];snap_ask_qty<=ask_qty[0];
     if(cur_type==4'd1)begin
      dict_delta[probe_idx]<=cur_price-offset_price;dict_qty[probe_idx]<=cur_qty16;dict_side[probe_idx]<=cur_side[0];level_found=0;apply_rank=LEVELS;
      if(cur_side[0]==0)begin
       for(j=0;j<LEVELS;j=j+1)begin if(bid_price[j]==cur_price&&bid_qty[j]!=0)begin bid_qty[j]<=bid_qty[j]+cur_qty;level_found=1;if(j==0)snap_bid_qty<=bid_qty[j]+cur_qty;end else if(apply_rank==LEVELS&&(bid_qty[j]==0||cur_price>bid_price[j]))apply_rank=j;end
       if(!level_found&&apply_rank<LEVELS)begin for(j=LEVELS-1;j>0;j=j-1)begin if(j>apply_rank)begin bid_price[j]<=bid_price[j-1];bid_qty[j]<=bid_qty[j-1];end end bid_price[apply_rank]<=cur_price;bid_qty[apply_rank]<=cur_qty;if(apply_rank==0)begin snap_bid_price<=cur_price;snap_bid_qty<=cur_qty;end end
      end else begin
       for(j=0;j<LEVELS;j=j+1)begin if(ask_price[j]==cur_price&&ask_qty[j]!=0)begin ask_qty[j]<=ask_qty[j]+cur_qty;level_found=1;if(j==0)snap_ask_qty<=ask_qty[j]+cur_qty;end else if(apply_rank==LEVELS&&(ask_qty[j]==0||cur_price<ask_price[j]))apply_rank=j;end
       if(!level_found&&apply_rank<LEVELS)begin for(j=LEVELS-1;j>0;j=j-1)begin if(j>apply_rank)begin ask_price[j]<=ask_price[j-1];ask_qty[j]<=ask_qty[j-1];end end ask_price[apply_rank]<=cur_price;ask_qty[apply_rank]<=cur_qty;if(apply_rank==0)begin snap_ask_price<=cur_price;snap_ask_qty<=cur_qty;end end
      end
     end else if((cur_type==4'd2||cur_type==4'd3)&&lookup_found)begin
      remove_qty=(cur_type==4'd2&&cur_qty16==0)?rd_qty:cur_qty;
      if(cur_type==4'd2||rd_qty<=remove_qty)begin dict_qty[probe_idx]<=0;dict_valid[probe_idx]<=0;end else dict_qty[probe_idx]<=rd_qty-remove_qty;
      for(j=0;j<LEVELS;j=j+1)begin
       if(rd_side==0&&bid_price[j]==lookup_price&&bid_qty[j]!=0)begin
        if(bid_qty[j]>remove_qty)begin bid_qty[j]<=bid_qty[j]-remove_qty;if(j==0)snap_bid_qty<=bid_qty[j]-remove_qty;end
        else begin for(i=j;i<LEVELS-1;i=i+1)begin bid_price[i]<=bid_price[i+1];bid_qty[i]<=bid_qty[i+1];end bid_price[LEVELS-1]<=0;bid_qty[LEVELS-1]<=0;if(j==0)begin snap_bid_price<=bid_price[1];snap_bid_qty<=bid_qty[1];end end
       end
       if(rd_side==1&&ask_price[j]==lookup_price&&ask_qty[j]!=0)begin
        if(ask_qty[j]>remove_qty)begin ask_qty[j]<=ask_qty[j]-remove_qty;if(j==0)snap_ask_qty<=ask_qty[j]-remove_qty;end
        else begin for(i=j;i<LEVELS-1;i=i+1)begin ask_price[i]<=ask_price[i+1];ask_qty[i]<=ask_qty[i+1];end ask_price[LEVELS-1]<=0;ask_qty[LEVELS-1]<=0;if(j==0)begin snap_ask_price<=ask_price[1];snap_ask_qty<=ask_qty[1];end end
       end
      end
     end
     if(cur_type==4'd1||lookup_found)begin bram_en<=1;bram_addr<=probe_idx;bram_wrdata<={cur_order,lookup_price};bram_we<={BRAM_DATA_WIDTH/8{1'b1}};end
     if(cur_type==4'd3)begin snap_trade<=lookup_price;last_trade_price<=lookup_price;last_timestamp<=cur_time;last_security<=cur_sec;end
     event_count<=event_count+1;state<=EMIT;
    end
    EMIT:begin
     if(!m_axis_snapshot_tvalid||m_axis_snapshot_tready)begin
      // Explicit 256-bit map: timestamp, trade, ask q/p, bid q/p, security,
      // type, side, and 8-bit flags/padding.
      m_axis_snapshot_tdata<={40'd0,cur_time,snap_trade,snap_ask_qty,snap_ask_price,snap_bid_qty,snap_bid_price,cur_sec,cur_type,cur_side,8'd0};
      m_axis_snapshot_tvalid<=1;m_axis_snapshot_tlast<=cur_last;state<=IDLE;
     end
    end
   endcase
  end
 end
endmodule
