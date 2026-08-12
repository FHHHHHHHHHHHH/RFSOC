`timescale 1ns / 1ps

module tb_dpd_mp_4lane_core;

    reg axis_clk = 1'b0;
    reg cfg_clk  = 1'b0;
    always #2.5 axis_clk = ~axis_clk;
    always #3.5 cfg_clk  = ~cfg_clk;

    reg axis_resetn = 1'b0;
    reg [127:0] s_axis_tdata = 128'd0;
    reg s_axis_tvalid = 1'b0;
    wire [127:0] m_axis_tdata;
    wire m_axis_tvalid;

    reg dpd_enable = 1'b0;
    reg commit_pulse = 1'b0;
    reg clear_clip_pulse = 1'b0;
    wire active_bank;
    wire [31:0] clip_count_gray;

    reg cfg_we = 1'b0;
    reg cfg_bank = 1'b0;
    reg [1:0] cfg_tap = 2'd0;
    reg [11:0] cfg_addr = 12'd0;
    reg [31:0] cfg_wdata = 32'd0;

    reg [127:0] expected_data [0:63];
    integer expected_write = 0;
    integer expected_read = 0;
    integer errors = 0;
    integer address_i;
    integer tap_i;

    function automatic [31:0] gray_to_binary;
        input [31:0] gray_value;
        integer bit_i;
        begin
            gray_to_binary[31] = gray_value[31];
            for (bit_i = 30; bit_i >= 0; bit_i = bit_i - 1)
                gray_to_binary[bit_i] = gray_to_binary[bit_i+1] ^ gray_value[bit_i];
        end
    endfunction

    function automatic [31:0] sample_word;
        input signed [15:0] value_i;
        input signed [15:0] value_q;
        begin
            sample_word = {value_q, value_i};
        end
    endfunction

    task automatic write_coefficient;
        input bank;
        input [1:0] tap;
        input [11:0] address;
        input signed [15:0] gain_i;
        input signed [15:0] gain_q;
        begin
            @(negedge cfg_clk);
            cfg_bank  <= bank;
            cfg_tap   <= tap;
            cfg_addr  <= address;
            cfg_wdata <= {gain_q, gain_i};
            cfg_we    <= 1'b1;
            @(negedge cfg_clk);
            cfg_we    <= 1'b0;
        end
    endtask

    task automatic send_and_expect;
        input [127:0] input_data;
        input [127:0] output_data;
        begin
            @(negedge axis_clk);
            s_axis_tdata  <= input_data;
            s_axis_tvalid <= 1'b1;
            expected_data[expected_write] = output_data;
            expected_write = expected_write + 1;
        end
    endtask

    always @(posedge axis_clk) begin
        #0.5;
        if (m_axis_tvalid) begin
            if (expected_read >= expected_write) begin
                $display("ERROR: unexpected output %h at %0t", m_axis_tdata, $time);
                errors = errors + 1;
            end else if (m_axis_tdata !== expected_data[expected_read]) begin
                $display("ERROR: output[%0d] expected %h got %h at %0t",
                         expected_read, expected_data[expected_read], m_axis_tdata, $time);
                errors = errors + 1;
            end
            expected_read = expected_read + 1;
        end
    end

    dpd_mp_4lane_core dut (
        .axis_clk(axis_clk),
        .axis_resetn(axis_resetn),
        .s_axis_tdata(s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .m_axis_tdata(m_axis_tdata),
        .m_axis_tvalid(m_axis_tvalid),
        .dpd_enable(dpd_enable),
        .commit_pulse(commit_pulse),
        .clear_clip_pulse(clear_clip_pulse),
        .active_bank(active_bank),
        .clip_count_gray(clip_count_gray),
        .cfg_clk(cfg_clk),
        .cfg_we(cfg_we),
        .cfg_bank(cfg_bank),
        .cfg_tap(cfg_tap),
        .cfg_addr(cfg_addr),
        .cfg_wdata(cfg_wdata)
    );

    initial begin
        // Bank 0: identity predistorter.  Bank 1: 1.5x gain for clipping test.
        // Initialize every address so the test also checks all replicated RAMs.
        for (tap_i = 0; tap_i < 4; tap_i = tap_i + 1) begin
            for (address_i = 0; address_i < 4096; address_i = address_i + 1) begin
                if (tap_i == 0) begin
                    write_coefficient(1'b0, tap_i[1:0], address_i[11:0], 16'sd16384, 16'sd0);
                    write_coefficient(1'b1, tap_i[1:0], address_i[11:0], 16'sd24576, 16'sd0);
                end else begin
                    write_coefficient(1'b0, tap_i[1:0], address_i[11:0], 16'sd0, 16'sd0);
                    write_coefficient(1'b1, tap_i[1:0], address_i[11:0], 16'sd0, 16'sd0);
                end
            end
        end

        repeat (4) @(posedge axis_clk);
        axis_resetn <= 1'b1;
        repeat (3) @(posedge axis_clk);

        // Latency-matched bypass.
        dpd_enable <= 1'b0;
        send_and_expect({sample_word(16'sd4000, -16'sd500),
                         sample_word(-16'sd3000, 16'sd750),
                         sample_word(16'sd2000, 16'sd250),
                         sample_word(16'sd1000, -16'sd125)},
                        {sample_word(16'sd4000, -16'sd500),
                         sample_word(-16'sd3000, 16'sd750),
                         sample_word(16'sd2000, 16'sd250),
                         sample_word(16'sd1000, -16'sd125)});

        // Identity coefficients in active bank 0.
        dpd_enable <= 1'b1;
        send_and_expect({sample_word(-16'sd8000, 16'sd1000),
                         sample_word(16'sd7000, -16'sd900),
                         sample_word(-16'sd6000, -16'sd800),
                         sample_word(16'sd5000, 16'sd700)},
                        {sample_word(-16'sd8000, 16'sd1000),
                         sample_word(16'sd7000, -16'sd900),
                         sample_word(-16'sd6000, -16'sd800),
                         sample_word(16'sd5000, 16'sd700)});

        send_and_expect({sample_word(16'sd12000, -16'sd1100),
                         sample_word(-16'sd11000, 16'sd1000),
                         sample_word(16'sd10000, 16'sd900),
                         sample_word(-16'sd9000, -16'sd800)},
                        {sample_word(16'sd12000, -16'sd1100),
                         sample_word(-16'sd11000, 16'sd1000),
                         sample_word(16'sd10000, 16'sd900),
                         sample_word(-16'sd9000, -16'sd800)});

        @(negedge axis_clk);
        s_axis_tvalid <= 1'b0;
        repeat (6) @(posedge axis_clk);

        // Atomically switch to bank 1 and verify positive/negative saturation.
        @(negedge axis_clk);
        commit_pulse <= 1'b1;
        @(negedge axis_clk);
        commit_pulse <= 1'b0;
        repeat (2) @(posedge axis_clk);

        send_and_expect({sample_word(16'sd30000, 16'sd30000),
                         sample_word(-16'sd30000, -16'sd30000),
                         sample_word(16'sd25000, -16'sd25000),
                         sample_word(-16'sd25000, 16'sd25000)},
                        {sample_word(16'sd32767, 16'sd32767),
                         sample_word(-16'sd32768, -16'sd32768),
                         sample_word(16'sd32767, -16'sd32768),
                         sample_word(-16'sd32768, 16'sd32767)});

        @(negedge axis_clk);
        s_axis_tvalid <= 1'b0;
        repeat (8) @(posedge axis_clk);

        if (expected_read != expected_write) begin
            $display("ERROR: expected %0d outputs, received %0d", expected_write, expected_read);
            errors = errors + 1;
        end

        if (!active_bank) begin
            $display("ERROR: bank commit did not activate bank 1");
            errors = errors + 1;
        end

        if (gray_to_binary(clip_count_gray) == 0) begin
            $display("ERROR: clipping counter did not increment");
            errors = errors + 1;
        end

        if (errors == 0)
            $display("TEST PASSED: four-lane MP-DPD bypass, identity, bank commit and saturation");
        else
            $display("TEST FAILED: %0d error(s)", errors);

        $finish;
    end

endmodule

