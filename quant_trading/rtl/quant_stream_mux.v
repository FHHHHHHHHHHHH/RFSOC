`timescale 1ns/1ps
module quant_stream_mux(
 input wire aclk,input wire aresetn,
 input wire [255:0] s_snapshot_tdata,input wire s_snapshot_tvalid,output wire s_snapshot_tready,input wire s_snapshot_tlast,
 input wire [63:0] s_signal_tdata,input wire s_signal_tvalid,output wire s_signal_tready,input wire s_signal_tlast,
 output reg [255:0] m_axis_tdata,output reg m_axis_tvalid,input wire m_axis_tready,output reg m_axis_tlast
);
 reg select_signal;
 assign s_snapshot_tready = !m_axis_tvalid && !select_signal;
 assign s_signal_tready = !m_axis_tvalid && select_signal;
 always @(posedge aclk) begin
  if(!aresetn)begin select_signal<=0;m_axis_tvalid<=0;m_axis_tdata<=0;m_axis_tlast<=0;end
  else begin
   if(m_axis_tvalid&&m_axis_tready)m_axis_tvalid<=0;
   if(!m_axis_tvalid) begin
    if(s_signal_tvalid)begin select_signal<=1;m_axis_tdata<={{192{1'b0}},s_signal_tdata};m_axis_tvalid<=1;m_axis_tlast<=s_signal_tlast;end
    else if(s_snapshot_tvalid)begin select_signal<=0;m_axis_tdata<=s_snapshot_tdata;m_axis_tvalid<=1;m_axis_tlast<=s_snapshot_tlast;end
   end
  end
 end
endmodule
