`timescale 1ns/1ps
module tb_market_sequence;
 reg clk=0,rstn=0;always #2 clk=~clk;
 reg [127:0] event_data=0;reg event_valid=0,event_last=1;wire event_ready;
 wire [127:0] ordered;wire ordered_valid,ordered_ready,ordered_last;
 wire [255:0] snapshot;wire snapshot_valid;reg snapshot_ready=1;integer snap_count=0;
 market_event_reorder ro(.aclk(clk),.aresetn(rstn),.s_axis_tdata(event_data),.s_axis_tvalid(event_valid),.s_axis_tready(event_ready),.s_axis_tlast(event_last),.m_axis_tdata(ordered),.m_axis_tvalid(ordered_valid),.m_axis_tready(ordered_ready),.m_axis_tlast(ordered_last));
 order_book_engine_ip ob(.aclk(clk),.aresetn(rstn),.s_axi_ctrl_awaddr(8'd0),.s_axi_ctrl_awvalid(0),.s_axi_ctrl_awready(),.s_axi_ctrl_wdata(0),.s_axi_ctrl_wstrb(0),.s_axi_ctrl_wvalid(0),.s_axi_ctrl_wready(),.s_axi_ctrl_bresp(),.s_axi_ctrl_bvalid(),.s_axi_ctrl_bready(1),.s_axi_ctrl_araddr(8'd0),.s_axi_ctrl_arvalid(0),.s_axi_ctrl_arready(),.s_axi_ctrl_rdata(),.s_axi_ctrl_rresp(),.s_axi_ctrl_rvalid(),.s_axi_ctrl_rready(1),.s_axis_decoded_tdata(ordered),.s_axis_decoded_tvalid(ordered_valid),.s_axis_decoded_tready(ordered_ready),.s_axis_decoded_tlast(ordered_last),.m_axis_snapshot_tdata(snapshot),.m_axis_snapshot_tvalid(snapshot_valid),.m_axis_snapshot_tready(snapshot_ready),.m_axis_snapshot_tlast(),.bram_clk(),.bram_en(),.bram_addr(),.bram_wrdata(),.bram_rddata(64'd0),.bram_we());
 task send_event(input [31:0] oid,input [15:0] qty,input [31:0] price,input [31:0] stamp,input [7:0] sec,input [3:0] side,input [3:0] typ);begin
  @(posedge clk);while(!event_ready)@(posedge clk);event_data<={oid,qty,price,stamp,sec,side,typ};event_valid<=1;
  @(posedge clk);while(!event_ready)@(posedge clk);event_valid<=0;
 end endtask
 task expect_snapshot(input [3:0] typ,input [31:0] trade,input [31:0] bidp,input [31:0] bidq);begin
  @(posedge clk);while(!snapshot_valid)@(posedge clk);#1;
  if(snapshot[15:12]!==typ||snapshot[183:152]!==trade||snapshot[55:24]!==bidp||snapshot[87:56]!==bidq)begin
   $display("FAIL snapshot%0d type=%0d trade=%0d bid=%0d/%0d raw=%h",snap_count,snapshot[15:12],snapshot[183:152],snapshot[55:24],snapshot[87:56],snapshot);$finish;
  end
  snap_count=snap_count+1;while(snapshot_valid)@(posedge clk);
 end endtask
 initial begin
  repeat(5)@(posedge clk);rstn<=1;
  send_event(42,10,1000,100,5,0,1);expect_snapshot(1,0,1000,10);
  // Trade arrives first, then an order with the same timestamp. Reorder must
  // present order 43 before trade 42 to the book engine.
  send_event(42,4,9999,200,5,0,3);
  send_event(43,5,1010,200,5,0,1);
  expect_snapshot(1,0,1010,5);
  expect_snapshot(3,1000,1010,5);
  send_event(43,5,1010,201,5,0,2);expect_snapshot(2,1000,1000,6);
  // ID 1066 aliases ID 42 in the low ten hash bits and exercises probing.
  send_event(1066,7,990,202,5,0,1);expect_snapshot(1,1000,1000,6);
  if(ob.collision_count==0)begin $display("FAIL collision path not exercised");$finish;end
  $display("PASS sequence snapshots=%0d collisions=%0d",snap_count,ob.collision_count);$finish;
 end
 initial begin #10000;$display("FAIL sequence timeout");$finish;end
endmodule
