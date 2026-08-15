`timescale 1ns / 1ps

module tb_axis_dpd_mp_4lane_dual;

    reg axis_clk = 1'b0;
    reg s_axi_aclk = 1'b0;
    always #2.712 axis_clk = ~axis_clk;
    always #5.000 s_axi_aclk = ~s_axi_aclk;

    reg axis_resetn = 1'b0;
    reg s_axi_aresetn = 1'b0;

    reg [127:0] s_axis_tdata = 128'd0;
    reg s_axis_tvalid = 1'b0;
    wire [127:0] m0_axis_tdata;
    wire m0_axis_tvalid;
    wire [127:0] m1_axis_tdata;
    wire m1_axis_tvalid;

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

    wire dpd_active_bank;
    wire [31:0] dpd_clip_count;

    integer errors = 0;
    reg [31:0] read_value;
    reg [127:0] bypass_word;

    task automatic axi_write;
        input [17:0] address;
        input [31:0] data;
        input [3:0] strobes;
        begin
            @(negedge s_axi_aclk);
            s_axi_awaddr  <= address;
            s_axi_awvalid <= 1'b1;
            s_axi_wdata   <= data;
            s_axi_wstrb   <= strobes;
            s_axi_wvalid  <= 1'b1;
            s_axi_bready  <= 1'b1;

            while (!(s_axi_awready && s_axi_wready))
                @(negedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_awvalid <= 1'b0;
            s_axi_wvalid  <= 1'b0;

            while (!s_axi_bvalid)
                @(negedge s_axi_aclk);
            if (s_axi_bresp != 2'b00) begin
                $display("ERROR: AXI write response %b for address %h", s_axi_bresp, address);
                errors = errors + 1;
            end
            @(negedge s_axi_aclk);
            s_axi_bready <= 1'b0;
        end
    endtask

    task automatic axi_read;
        input [17:0] address;
        output [31:0] data;
        begin
            @(negedge s_axi_aclk);
            s_axi_araddr  <= address;
            s_axi_arvalid <= 1'b1;
            s_axi_rready  <= 1'b1;

            while (!s_axi_arready)
                @(negedge s_axi_aclk);
            @(negedge s_axi_aclk);
            s_axi_arvalid <= 1'b0;

            while (!s_axi_rvalid)
                @(negedge s_axi_aclk);
            data = s_axi_rdata;
            if (s_axi_rresp != 2'b00) begin
                $display("ERROR: AXI read response %b for address %h", s_axi_rresp, address);
                errors = errors + 1;
            end
            @(negedge s_axi_aclk);
            s_axi_rready <= 1'b0;
        end
    endtask

    axis_dpd_mp_4lane_dual dut (
        .axis_clk(axis_clk),
        .axis_resetn(axis_resetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .m0_axis_tdata(m0_axis_tdata),
        .m0_axis_tvalid(m0_axis_tvalid),
        .m1_axis_tdata(m1_axis_tdata),
        .m1_axis_tvalid(m1_axis_tvalid),
        .s_axi_aclk(s_axi_aclk),
        .s_axi_aresetn(s_axi_aresetn),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awprot(s_axi_awprot),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arprot(s_axi_arprot),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .dpd_active_bank(dpd_active_bank),
        .dpd_clip_count(dpd_clip_count)
    );

    initial begin
        repeat (6) @(posedge s_axi_aclk);
        s_axi_aresetn <= 1'b1;
        repeat (6) @(posedge axis_clk);
        axis_resetn <= 1'b1;
        repeat (6) @(posedge s_axi_aclk);

        axi_read(18'h0000C, read_value);
        if (read_value !== 32'h4450_4401) begin
            $display("ERROR: version expected 44504401, got %h", read_value);
            errors = errors + 1;
        end

        axi_read(18'h00000, read_value);
        if (read_value !== 32'd0) begin
            $display("ERROR: control reset value expected 0, got %h", read_value);
            errors = errors + 1;
        end

        // Bank 1, tap 0, LUT address 0: unity complex gain.  Small samples
        // below map to address zero, providing an end-to-end check that the
        // AXI write crossed the asynchronous FIFO and reached all lane RAMs.
        axi_write(18'h30000, 32'h0000_4000, 4'b1111);
        repeat (10) @(posedge axis_clk);

        axi_write(18'h00000, 32'h0000_0001, 4'b0001);
        repeat (10) @(posedge s_axi_aclk);
        axi_read(18'h00004, read_value);
        if (read_value[1:0] !== 2'b10) begin
            $display("ERROR: enabled status expected 2'b10, got %b", read_value[1:0]);
            errors = errors + 1;
        end

        axi_write(18'h00000, 32'h0000_0003, 4'b0001);
        repeat (10) @(posedge s_axi_aclk);
        axi_read(18'h00004, read_value);
        if (read_value[1:0] !== 2'b11 || !dpd_active_bank) begin
            $display("ERROR: committed status expected 2'b11, got %b", read_value[1:0]);
            errors = errors + 1;
        end


        @(negedge axis_clk);
        s_axis_tdata <= {
            32'h0000_0040, 32'h0000_0030,
            32'h0000_0020, 32'h0000_0010
        };
        s_axis_tvalid <= 1'b1;
        @(negedge axis_clk);
        s_axis_tvalid <= 1'b0;
        @(posedge m0_axis_tvalid);
        #0.1;
        if (m0_axis_tdata !== {
                32'h0000_0040, 32'h0000_0030,
                32'h0000_0020, 32'h0000_0010
            } || m1_axis_tdata !== m0_axis_tdata) begin
            $display("ERROR: coefficient FIFO/RAM datapath mismatch: %h", m0_axis_tdata);
            errors = errors + 1;
        end

        // Deposit a count to exercise Gray-code synchronization and clear.
        dut.u_impl.u_dpd_core.clip_count_bin = 32'd7;
        repeat (8) @(posedge s_axi_aclk);
        axi_read(18'h00008, read_value);
        if (read_value !== 32'd7 || dpd_clip_count !== 32'd7) begin
            $display("ERROR: clip count expected 7, got %0d", read_value);
            errors = errors + 1;
        end

        axi_write(18'h00000, 32'h0000_0005, 4'b0001);
        repeat (10) @(posedge s_axi_aclk);
        axi_read(18'h00008, read_value);
        if (read_value !== 32'd0) begin
            $display("ERROR: clip counter clear failed, got %0d", read_value);
            errors = errors + 1;
        end

        // Disable DPD and verify latency-matched bypass is duplicated.
        axi_write(18'h00000, 32'h0000_0000, 4'b0001);
        repeat (6) @(posedge axis_clk);
        bypass_word = 128'hFEDC_BA98_7654_3210_0123_4567_89AB_CDEF;
        @(negedge axis_clk);
        s_axis_tdata <= bypass_word;
        s_axis_tvalid <= 1'b1;
        @(negedge axis_clk);
        s_axis_tvalid <= 1'b0;
        @(posedge m0_axis_tvalid);
        #0.1;
        if (!m1_axis_tvalid || m0_axis_tdata !== bypass_word || m1_axis_tdata !== bypass_word) begin
            $display("ERROR: dual-output bypass mismatch: m0=%h m1=%h", m0_axis_tdata, m1_axis_tdata);
            errors = errors + 1;
        end

        if (errors == 0)
            $display("TEST PASSED: AXI-Lite registers, LUT write, CDC, bank commit and dual bypass");
        else
            $display("TEST FAILED: %0d error(s)", errors);

        $finish;
    end

endmodule
