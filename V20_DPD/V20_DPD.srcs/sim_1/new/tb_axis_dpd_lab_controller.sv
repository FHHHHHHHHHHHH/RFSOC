`timescale 1ns / 1ps

module tb_axis_dpd_lab_controller;
    reg axis_clk = 1'b0;
    reg s_axi_aclk = 1'b0;
    always #2.712 axis_clk = ~axis_clk;
    always #5.000 s_axi_aclk = ~s_axi_aclk;

    reg axis_resetn = 1'b0;
    reg s_axi_aresetn = 1'b0;
    reg [127:0] s_dbpsk_axis_tdata = 128'h4444_0004_3333_0003_2222_0002_1111_0001;
    reg s_dbpsk_axis_tvalid = 1'b1;
    wire [127:0] m_tx_axis_tdata;
    wire m_tx_axis_tvalid;
    reg [31:0] s_adc_i_axis_tdata = 32'd0;
    reg s_adc_i_axis_tvalid = 1'b0;
    reg [31:0] s_adc_q_axis_tdata = 32'd0;
    reg s_adc_q_axis_tvalid = 1'b0;

    reg [17:0] s_axi_awaddr = 18'd0;
    reg [2:0] s_axi_awprot = 3'd0;
    reg s_axi_awvalid = 1'b0;
    wire s_axi_awready;
    reg [31:0] s_axi_wdata = 32'd0;
    reg [3:0] s_axi_wstrb = 4'd0;
    reg s_axi_wvalid = 1'b0;
    wire s_axi_wready;
    wire [1:0] s_axi_bresp;
    wire s_axi_bvalid;
    reg s_axi_bready = 1'b0;
    reg [17:0] s_axi_araddr = 18'd0;
    reg [2:0] s_axi_arprot = 3'd0;
    reg s_axi_arvalid = 1'b0;
    wire s_axi_arready;
    wire [31:0] s_axi_rdata;
    wire [1:0] s_axi_rresp;
    wire s_axi_rvalid;
    reg s_axi_rready = 1'b0;
    wire playback_active;
    wire capture_busy;
    wire capture_done;
    wire [12:0] capture_count;

    integer errors = 0;
    integer sample_i;
    reg [31:0] read_value;

    task automatic axi_write;
        input [17:0] address;
        input [31:0] data;
        begin
            @(negedge s_axi_aclk);
            s_axi_awaddr <= address;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata <= data;
            s_axi_wstrb <= 4'hF;
            s_axi_wvalid <= 1'b1;
            s_axi_bready <= 1'b1;
            while (!(s_axi_awready && s_axi_wready))
                @(negedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid <= 1'b0;
            while (!s_axi_bvalid)
                @(negedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task automatic axi_read;
        input [17:0] address;
        output [31:0] data;
        begin
            @(negedge s_axi_aclk);
            s_axi_araddr <= address;
            s_axi_arvalid <= 1'b1;
            s_axi_rready <= 1'b1;
            while (!s_axi_arready)
                @(negedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_arvalid <= 1'b0;
            while (!s_axi_rvalid)
                @(negedge s_axi_aclk);
            data = s_axi_rdata;
            @(negedge s_axi_aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    axis_dpd_lab_controller dut (.*);

    initial begin
        repeat (5) @(posedge s_axi_aclk);
        s_axi_aresetn <= 1'b1;
        repeat (5) @(posedge axis_clk);
        axis_resetn <= 1'b1;

        axi_read(18'h00014, read_value);
        if (read_value !== 32'h4C41_4202) begin
            $display("ERROR: bad LAB version %h", read_value);
            errors = errors + 1;
        end

        // Program an eight-sample waveform.
        axi_write(18'h10000, 32'h0010_0001);
        axi_write(18'h10004, 32'h0011_0002);
        axi_write(18'h10008, 32'h0012_0003);
        axi_write(18'h1000C, 32'h0013_0004);
        axi_write(18'h10010, 32'h0014_0005);
        axi_write(18'h10014, 32'h0015_0006);
        axi_write(18'h10018, 32'h0016_0007);
        axi_write(18'h1001C, 32'h0017_0008);
        axi_write(18'h00008, 32'd8);
        axi_write(18'h00000, 32'd1);
        repeat (8) @(posedge axis_clk);
        if (!playback_active || !m_tx_axis_tvalid ||
            m_tx_axis_tdata !== 128'h0013_0004_0012_0003_0011_0002_0010_0001) begin
            $display("ERROR: waveform playback mismatch %h", m_tx_axis_tdata);
            errors = errors + 1;
        end

        // Capture four samples (two sample pairs).
        axi_write(18'h0000C, 32'd4);
        axi_write(18'h00000, 32'd2);
        repeat (8) @(posedge axis_clk);
        @(negedge axis_clk);
        s_dbpsk_axis_tdata <= 128'hDDDD_000D_CCCC_000C_BBBB_000B_AAAA_000A;
        s_adc_i_axis_tdata <= 32'h0021_0020;
        s_adc_q_axis_tdata <= 32'h0031_0030;
        s_adc_i_axis_tvalid <= 1'b1;
        s_adc_q_axis_tvalid <= 1'b1;
        @(negedge axis_clk);
        s_dbpsk_axis_tdata <= 128'h1111_0011_FFFF_000F_EEEE_000E_DDDD_000D;
        s_adc_i_axis_tdata <= 32'h0023_0022;
        s_adc_q_axis_tdata <= 32'h0033_0032;
        @(negedge axis_clk);
        s_adc_i_axis_tvalid <= 1'b0;
        s_adc_q_axis_tvalid <= 1'b0;
        repeat (8) @(posedge s_axi_aclk);

        if (!capture_done || capture_busy || capture_count != 13'd4) begin
            $display("ERROR: capture status done=%b busy=%b count=%0d",
                     capture_done, capture_busy, capture_count);
            errors = errors + 1;
        end

        axi_read(18'h20000, read_value);
        if (read_value !== 32'hAAAA_000A) begin
            $display("ERROR: capture TX0 mismatch %h", read_value);
            errors = errors + 1;
        end
        axi_read(18'h20004, read_value);
        if (read_value !== 32'h0030_0020) begin
            $display("ERROR: capture ADC0 mismatch %h", read_value);
            errors = errors + 1;
        end
        axi_read(18'h20008, read_value);
        if (read_value !== 32'hCCCC_000C) begin
            $display("ERROR: capture TX1 mismatch %h", read_value);
            errors = errors + 1;
        end
        axi_read(18'h2000C, read_value);
        if (read_value !== 32'h0031_0021) begin
            $display("ERROR: capture ADC1 mismatch %h", read_value);
            errors = errors + 1;
        end

        axi_write(18'h00000, 32'd0);
        repeat (5) @(posedge axis_clk);
        if (m_tx_axis_tdata !== s_dbpsk_axis_tdata || !m_tx_axis_tvalid) begin
            $display("ERROR: DBPSK bypass mismatch");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("TEST PASSED: LAB playback, capture and AXI-Lite access");
        else
            $display("TEST FAILED: %0d error(s)", errors);
        $finish;
    end
endmodule
