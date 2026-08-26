`timescale 1ns/1ps
module tb_fast_orderbook;
 reg clk=0,rstn=0;always #2 clk=~clk;
 reg[511:0]raw=0;reg raw_valid=0;wire raw_ready;reg raw_last=0;wire[127:0]decoded;wire decoded_valid;wire decoded_ready;wire decoded_last;
 wire[127:0]ordered;wire ordered_valid,ordered_ready,ordered_last;wire[255:0]snapshot;wire snapshot_valid;reg snapshot_ready=1;
 wire[63:0]bram_wr;wire[15:0]bram_addr;wire[7:0]bram_we;
 fast_decoder_ip fd(.aclk(clk),.aresetn(rstn),.s_axi_ctrl_awaddr(8'd0),.s_axi_ctrl_awvalid(0),.s_axi_ctrl_awready(),.s_axi_ctrl_wdata(0),.s_axi_ctrl_wstrb(0),.s_axi_ctrl_wvalid(0),.s_axi_ctrl_wready(),.s_axi_ctrl_bresp(),.s_axi_ctrl_bvalid(),.s_axi_ctrl_bready(1),.s_axi_ctrl_araddr(0),.s_axi_ctrl_arvalid(0),.s_axi_ctrl_arready(),.s_axi_ctrl_rdata(),.s_axi_ctrl_rresp(),.s_axi_ctrl_rvalid(),.s_axi_ctrl_rready(1),.s_axis_raw_tdata(raw),.s_axis_raw_tvalid(raw_valid),.s_axis_raw_tready(raw_ready),.s_axis_raw_tlast(raw_last),.m_axis_decoded_tdata(decoded),.m_axis_decoded_tvalid(decoded_valid),.m_axis_decoded_tready(decoded_ready),.m_axis_decoded_tlast(decoded_last));
 market_event_reorder ro(.aclk(clk),.aresetn(rstn),.s_axis_tdata(decoded),.s_axis_tvalid(decoded_valid),.s_axis_tready(decoded_ready),.s_axis_tlast(decoded_last),.m_axis_tdata(ordered),.m_axis_tvalid(ordered_valid),.m_axis_tready(ordered_ready),.m_axis_tlast(ordered_last));
 order_book_engine_ip ob(.aclk(clk),.aresetn(rstn),.s_axi_ctrl_awaddr(8'd0),.s_axi_ctrl_awvalid(0),.s_axi_ctrl_awready(),.s_axi_ctrl_wdata(0),.s_axi_ctrl_wstrb(0),.s_axi_ctrl_wvalid(0),.s_axi_ctrl_wready(),.s_axi_ctrl_bresp(),.s_axi_ctrl_bvalid(),.s_axi_ctrl_bready(1),.s_axi_ctrl_araddr(0),.s_axi_ctrl_arvalid(0),.s_axi_ctrl_arready(),.s_axi_ctrl_rdata(),.s_axi_ctrl_rresp(),.s_axi_ctrl_rvalid(),.s_axi_ctrl_rready(1),.s_axis_decoded_tdata(ordered),.s_axis_decoded_tvalid(ordered_valid),.s_axis_decoded_tready(ordered_ready),.s_axis_decoded_tlast(ordered_last),.m_axis_snapshot_tdata(snapshot),.m_axis_snapshot_tvalid(snapshot_valid),.m_axis_snapshot_tready(snapshot_ready),.m_axis_snapshot_tlast(),.bram_clk(),.bram_en(),.bram_addr(bram_addr),.bram_wrdata(bram_wr),.bram_rddata(0),.bram_we(bram_we));
 initial begin
  repeat(5)@(posedge clk);rstn<=1;
  raw[7:0]=8'h39;raw[15:8]=8'h35;raw[23:16]=8'h3d;raw[31:24]=8'h39;raw[39:32]=8'h01;
  raw[47:40]=8'h39;raw[55:48]=8'h36;raw[63:56]=8'h3d;raw[71:64]=8'hff;
  raw[79:72]=8'h81;raw[87:80]=8'h80;raw[95:88]=8'h85;raw[103:96]=8'he4;
  raw[111:104]=8'h07;raw[119:112]=8'he8;raw[127:120]=8'h8a;raw[135:128]=8'haa;
  @(posedge clk);raw_valid<=1;raw_last<=1;@(posedge clk);while(!raw_ready)@(posedge clk);raw_valid<=0;raw_last<=0;
  wait(decoded_valid);
  if(decoded!=={32'd42,16'd10,32'd1000,32'd100,8'd5,4'd0,4'd1})begin $display("FAIL decoded=%h",decoded);$finish;end
  if(fd.step_length!==32'd9)begin $display("FAIL STEP length=%0d",fd.step_length);$finish;end
  wait(snapshot_valid);$display("PASS decoded=%h snapshot=%h",decoded,snapshot);$finish;
 end
 initial begin #5000;$display("FAIL timeout");$finish;end
endmodule
