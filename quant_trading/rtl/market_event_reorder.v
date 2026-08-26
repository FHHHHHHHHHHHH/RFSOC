`timescale 1ns/1ps
// Hold trades until the next event is known. For equal timestamps an order
// arriving after a trade is emitted first, followed by the held trade.
module market_event_reorder(
 input wire aclk,input wire aresetn,
 input wire [127:0] s_axis_tdata,input wire s_axis_tvalid,output wire s_axis_tready,input wire s_axis_tlast,
 output reg [127:0] m_axis_tdata,output reg m_axis_tvalid,input wire m_axis_tready,output reg m_axis_tlast
);
 reg hold_valid,follow_valid;reg[127:0]hold_data,follow_data;reg hold_last,follow_last;
 wire [3:0] in_type=s_axis_tdata[3:0];wire[31:0]in_time=s_axis_tdata[47:16];wire[31:0]hold_time=hold_data[47:16];
 wire output_free=!m_axis_tvalid||m_axis_tready;
 assign s_axis_tready=output_free&&!follow_valid;
 always @(posedge aclk)begin
  if(!aresetn)begin hold_valid<=0;follow_valid<=0;hold_data<=0;follow_data<=0;hold_last<=0;follow_last<=0;m_axis_tdata<=0;m_axis_tvalid<=0;m_axis_tlast<=0;end
  else begin
   if(m_axis_tvalid&&m_axis_tready)m_axis_tvalid<=0;
   if(output_free&&follow_valid)begin m_axis_tdata<=follow_data;m_axis_tvalid<=1;m_axis_tlast<=follow_last;follow_valid<=0;end
   else if(s_axis_tvalid&&s_axis_tready)begin
    if(hold_valid)begin
     if(in_type==4'd1&&in_time==hold_time)begin
      m_axis_tdata<=s_axis_tdata;m_axis_tvalid<=1;m_axis_tlast<=0;follow_data<=hold_data;follow_last<=hold_last;follow_valid<=1;hold_valid<=0;
     end else begin
      m_axis_tdata<=hold_data;m_axis_tvalid<=1;m_axis_tlast<=hold_last;
      if(in_type==4'd3)begin hold_data<=s_axis_tdata;hold_last<=s_axis_tlast;hold_valid<=1;end else begin follow_data<=s_axis_tdata;follow_last<=s_axis_tlast;follow_valid<=1;hold_valid<=0;end
     end
    end else if(in_type==4'd3)begin hold_data<=s_axis_tdata;hold_last<=s_axis_tlast;hold_valid<=1;end
    else begin m_axis_tdata<=s_axis_tdata;m_axis_tvalid<=1;m_axis_tlast<=s_axis_tlast;end
   end
  end
 end
endmodule
