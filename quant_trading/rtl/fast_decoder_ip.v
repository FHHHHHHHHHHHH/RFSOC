`timescale 1ns/1ps
// STEP/FAST streaming decoder. Byte zero is the least-significant byte of the
// AXIS beat. Both a bare 96= envelope and 95=<length><SOH>96= are accepted.
// Normalized record: {order_id, quantity, price, timestamp, security_id, side,
// msg_type} = 128 bits.
module fast_decoder_ip #(parameter integer RAW_WIDTH=512, parameter integer DECODED_WIDTH=128)(
 input wire aclk,input wire aresetn,
 input wire [7:0] s_axi_ctrl_awaddr,input wire s_axi_ctrl_awvalid,output wire s_axi_ctrl_awready,
 input wire [31:0] s_axi_ctrl_wdata,input wire [3:0] s_axi_ctrl_wstrb,input wire s_axi_ctrl_wvalid,output wire s_axi_ctrl_wready,
 output wire [1:0] s_axi_ctrl_bresp,output wire s_axi_ctrl_bvalid,input wire s_axi_ctrl_bready,
 input wire [7:0] s_axi_ctrl_araddr,input wire s_axi_ctrl_arvalid,output wire s_axi_ctrl_arready,
 output wire [31:0] s_axi_ctrl_rdata,output wire [1:0] s_axi_ctrl_rresp,output wire s_axi_ctrl_rvalid,input wire s_axi_ctrl_rready,
 input wire [RAW_WIDTH-1:0] s_axis_raw_tdata,input wire s_axis_raw_tvalid,output wire s_axis_raw_tready,input wire s_axis_raw_tlast,
 output reg [DECODED_WIDTH-1:0] m_axis_decoded_tdata,output reg m_axis_decoded_tvalid,input wire m_axis_decoded_tready,output reg m_axis_decoded_tlast
);
 localparam [3:0] ST_SCAN=0,ST_TAG9=1,ST_TAG95=2,ST_TAG96=3,ST_LEN=4,ST_PMAP=5,ST_FIELD=6;
 localparam [2:0] OP_DIRECT=0,OP_COPY=1,OP_DEFAULT=2,OP_INCREMENT=3,OP_DELTA=4,OP_CONSTANT=5;
 reg [3:0] state;reg [RAW_WIDTH-1:0] beat;reg active,last_beat;reg [5:0] pos;
 reg [55:0] pmap_shift;reg [5:0] pmap_bits,pmap_index;reg [3:0] field_no;
 reg [63:0] var_acc,merged_value;reg [6:0] var_len;reg [31:0] default_value[0:6];
 reg [31:0] prev_price,prev_qty,prev_order,prev_time;reg [7:0] prev_sec;reg [3:0] prev_side,prev_type;
 reg [3:0] msg_type,side;reg [7:0] security_id;reg [31:0] timestamp,price,order_id;reg [15:0] quantity;
 reg [31:0] control_reg,frame_count,byte_count,error_count,decoded_val,absent_val;
 reg [31:0] length_acc,fast_bytes,step_length;reg step_length_valid;
 reg aw_hold,w_hold,b_hold,r_hold;reg [7:0] awaddr;reg [31:0] wdata,rdata;integer k;
 wire [7:0] cbyte=beat[pos*8 +: 8];
 wire field_present=(pmap_index<pmap_bits)?pmap_shift[pmap_bits-1-pmap_index]:1'b0;
 wire [2:0] field_op=control_reg[field_no*3 +: 3];
 wire field_pmap=control_reg[24+field_no];
 wire field_has_value=(field_op!=OP_CONSTANT)&&(!field_pmap||field_present);
 assign s_axi_ctrl_awready=!aw_hold&&!b_hold;assign s_axi_ctrl_wready=!w_hold&&!b_hold;
 assign s_axi_ctrl_bresp=0;assign s_axi_ctrl_bvalid=b_hold;assign s_axi_ctrl_arready=!r_hold;
 assign s_axi_ctrl_rdata=rdata;assign s_axi_ctrl_rresp=0;assign s_axi_ctrl_rvalid=r_hold;
 assign s_axis_raw_tready=!active&&(!m_axis_decoded_tvalid||m_axis_decoded_tready);
 always @(posedge aclk) begin
  if(!aresetn)begin
   state<=ST_SCAN;beat<=0;active<=0;last_beat<=0;pos<=0;pmap_shift<=0;pmap_bits<=0;pmap_index<=0;field_no<=0;var_acc<=0;merged_value<=0;var_len<=0;
   prev_price<=0;prev_qty<=0;prev_order<=0;prev_time<=0;prev_sec<=0;prev_side<=0;prev_type<=0;msg_type<=0;side<=0;security_id<=0;timestamp<=0;price<=0;order_id<=0;quantity<=0;
   control_reg<=32'h7f000000;frame_count<=0;byte_count<=0;error_count<=0;decoded_val<=0;absent_val<=0;length_acc<=0;fast_bytes<=0;step_length<=0;step_length_valid<=0;
   aw_hold<=0;w_hold<=0;b_hold<=0;r_hold<=0;awaddr<=0;wdata<=0;rdata<=0;m_axis_decoded_tdata<=0;m_axis_decoded_tvalid<=0;m_axis_decoded_tlast<=0;
   for(k=0;k<7;k=k+1)default_value[k]<=0;
  end else begin
   if(s_axi_ctrl_awvalid&&s_axi_ctrl_awready)begin aw_hold<=1;awaddr<=s_axi_ctrl_awaddr;end
   if(s_axi_ctrl_wvalid&&s_axi_ctrl_wready)begin w_hold<=1;wdata<=s_axi_ctrl_wdata;end
   if(aw_hold&&w_hold&&!b_hold)begin if(awaddr[7:2]==0)control_reg<=wdata;else if(awaddr[7:2]>=8&&awaddr[7:2]<=14)default_value[awaddr[7:2]-8]<=wdata;aw_hold<=0;w_hold<=0;b_hold<=1;end
   if(b_hold&&s_axi_ctrl_bready)b_hold<=0;
   if(s_axi_ctrl_arvalid&&s_axi_ctrl_arready)begin case(s_axi_ctrl_araddr[7:2])0:rdata<=control_reg;1:rdata<=frame_count;2:rdata<=byte_count;3:rdata<=error_count;4:rdata<=step_length;8:rdata<=default_value[0];9:rdata<=default_value[1];10:rdata<=default_value[2];11:rdata<=default_value[3];12:rdata<=default_value[4];13:rdata<=default_value[5];14:rdata<=default_value[6];default:rdata<=32'h46535434;endcase r_hold<=1;end
   if(r_hold&&s_axi_ctrl_rready)r_hold<=0;
   if(m_axis_decoded_tvalid&&m_axis_decoded_tready)m_axis_decoded_tvalid<=0;
   if(s_axis_raw_tvalid&&s_axis_raw_tready)begin beat<=s_axis_raw_tdata;active<=1;last_beat<=s_axis_raw_tlast;pos<=0;end
   else if(active&&(!m_axis_decoded_tvalid||m_axis_decoded_tready))begin
    byte_count<=byte_count+1;
    case(state)
     ST_SCAN:if(cbyte==8'h39)state<=ST_TAG9;
     ST_TAG9:if(cbyte==8'h35)state<=ST_TAG95;else if(cbyte==8'h36)state<=ST_TAG96;else if(cbyte!=8'h39)state<=ST_SCAN;
     ST_TAG95:if(cbyte==8'h3d)begin length_acc<=0;state<=ST_LEN;end else begin state<=ST_SCAN;error_count<=error_count+1;end
     ST_LEN:begin if(cbyte>=8'h30&&cbyte<=8'h39)length_acc<=length_acc*10+(cbyte-8'h30);else if(cbyte==8'h01)begin step_length<=length_acc;step_length_valid<=1;state<=ST_SCAN;end else begin error_count<=error_count+1;state<=ST_SCAN;end end
     ST_TAG96:if(cbyte==8'h3d)begin state<=ST_PMAP;pmap_shift<=0;pmap_bits<=0;pmap_index<=0;field_no<=0;var_acc<=0;var_len<=0;fast_bytes<=0;end else begin state<=ST_SCAN;error_count<=error_count+1;end
     ST_PMAP:begin fast_bytes<=fast_bytes+1;if(pmap_bits<=49)begin pmap_shift<={pmap_shift[48:0],cbyte[6:0]};pmap_bits<=pmap_bits+7;if(cbyte[7])begin state<=ST_FIELD;field_no<=0;pmap_index<=0;end end else begin error_count<=error_count+1;state<=ST_SCAN;end end
     ST_FIELD:begin
      if(!field_has_value)begin
       case(field_op)
        OP_COPY:absent_val=(field_no==0)?prev_type:(field_no==1)?prev_side:(field_no==2)?prev_sec:(field_no==3)?prev_time:(field_no==4)?prev_price:(field_no==5)?prev_qty:prev_order;
        OP_DEFAULT,OP_CONSTANT:absent_val=default_value[field_no];
        OP_INCREMENT:absent_val=((field_no==0)?prev_type:(field_no==1)?prev_side:(field_no==2)?prev_sec:(field_no==3)?prev_time:(field_no==4)?prev_price:(field_no==5)?prev_qty:prev_order)+1;
        default:absent_val=0;
       endcase
       case(field_no)0:begin msg_type<=absent_val[3:0];prev_type<=absent_val[3:0];end 1:begin side<=absent_val[3:0];prev_side<=absent_val[3:0];end 2:begin security_id<=absent_val[7:0];prev_sec<=absent_val[7:0];end 3:begin timestamp<=absent_val;prev_time<=absent_val;end 4:begin price<=absent_val;prev_price<=absent_val;end 5:begin quantity<=absent_val[15:0];prev_qty<=absent_val;end 6:begin order_id<=absent_val;prev_order<=absent_val;m_axis_decoded_tdata<={absent_val,quantity,price,timestamp,security_id,side,msg_type};m_axis_decoded_tvalid<=1;m_axis_decoded_tlast<=1;frame_count<=frame_count+1;state<=ST_SCAN;end endcase
       if(field_pmap)pmap_index<=pmap_index+1;if(field_no==6)field_no<=0;else field_no<=field_no+1;
      end else begin
       merged_value=(var_acc<<7)|cbyte[6:0];var_acc<=merged_value;var_len<=var_len+1;fast_bytes<=fast_bytes+1;
       if(cbyte[7])begin
        case(field_no)0:decoded_val=(field_op==OP_DELTA)?prev_type+merged_value:merged_value;1:decoded_val=(field_op==OP_DELTA)?prev_side+merged_value:merged_value;2:decoded_val=(field_op==OP_DELTA)?prev_sec+merged_value:merged_value;3:decoded_val=(field_op==OP_DELTA)?prev_time+merged_value:merged_value;4:decoded_val=(field_op==OP_DELTA)?prev_price+merged_value:merged_value;5:decoded_val=(field_op==OP_DELTA)?prev_qty+merged_value:merged_value;default:decoded_val=(field_op==OP_DELTA)?prev_order+merged_value:merged_value;endcase
        case(field_no)0:begin msg_type<=decoded_val[3:0];prev_type<=decoded_val[3:0];end 1:begin side<=decoded_val[3:0];prev_side<=decoded_val[3:0];end 2:begin security_id<=decoded_val[7:0];prev_sec<=decoded_val[7:0];end 3:begin timestamp<=decoded_val;prev_time<=decoded_val;end 4:begin price<=decoded_val;prev_price<=decoded_val;end 5:begin quantity<=decoded_val[15:0];prev_qty<=decoded_val;end 6:begin order_id<=decoded_val;prev_order<=decoded_val;m_axis_decoded_tdata<={decoded_val,quantity,price,timestamp,security_id,side,msg_type};m_axis_decoded_tvalid<=1;m_axis_decoded_tlast<=1;frame_count<=frame_count+1;state<=ST_SCAN;end endcase
        var_acc<=0;var_len<=0;if(field_pmap)pmap_index<=pmap_index+1;if(field_no==6)field_no<=0;else field_no<=field_no+1;
       end
      end
     end
    endcase
    if(state==ST_FIELD&&!field_has_value)pos<=pos;else if(pos==63)begin active<=0;if(last_beat&&state!=ST_SCAN)begin error_count<=error_count+1;state<=ST_SCAN;end end else pos<=pos+1;
   end
  end
 end
endmodule
