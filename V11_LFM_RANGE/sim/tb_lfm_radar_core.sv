`timescale 1ns / 1ps

module tb_lfm_radar_core;
    localparam integer PULSE_SAMPLES   = 64;
    localparam integer CAPTURE_SAMPLES = 96;
    localparam integer MAX_LAG         = 16;
    localparam integer REF_DELAY       = 4;
    localparam integer TARGET_LAG      = 7;

    reg clk = 1'b0;
    always #2.712 clk = ~clk;

    reg rst_n = 1'b0;
    reg [31:0] ctrl_data = 32'd0;
    reg ctrl_valid = 1'b0;
    wire ctrl_ready;

    wire [31:0] result_data;
    wire result_valid;
    reg result_ready = 1'b1;
    wire result_last;

    wire [127:0] dac_data;
    wire dac_valid;
    wire [127:0] dac1_data;
    wire dac1_valid;
    reg [63:0] echo_i = 64'd0;
    reg [63:0] echo_q = 64'd0;
    reg [63:0] ref_i = 64'd0;
    reg [63:0] ref_q = 64'd0;
    reg target_enable = 1'b0;

    wire enabled;
    wire tx_active;
    wire capture_active;
    wire background_valid;

    lfm_radar_core #(
        .CLK_FREQ_HZ(184_320_000),
        .PRF_HZ(1_440_000),
        .PULSE_SAMPLES(PULSE_SAMPLES),
        .CAPTURE_SAMPLES(CAPTURE_SAMPLES),
        .MAX_LAG(MAX_LAG),
        .ROM_FILE("../mem/lfm_sim_64.mem")
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_ctrl_tdata(ctrl_data),
        .s_axis_ctrl_tvalid(ctrl_valid),
        .s_axis_ctrl_tready(ctrl_ready),
        .s_axis_ctrl_tlast(1'b1),
        .m_axis_result_tdata(result_data),
        .m_axis_result_tvalid(result_valid),
        .m_axis_result_tready(result_ready),
        .m_axis_result_tlast(result_last),
        .m0_axis_tdata(dac_data),
        .m0_axis_tvalid(dac_valid),
        .m1_axis_tdata(dac1_data),
        .m1_axis_tvalid(dac1_valid),
        .echo_i_axis_tdata(echo_i),
        .echo_i_axis_tvalid(1'b1),
        .echo_q_axis_tdata(echo_q),
        .echo_q_axis_tvalid(1'b1),
        .ref_i_axis_tdata(ref_i),
        .ref_i_axis_tvalid(1'b1),
        .ref_q_axis_tdata(ref_q),
        .ref_q_axis_tvalid(1'b1),
        .radar_enabled(enabled),
        .tx_active(tx_active),
        .capture_active(capture_active),
        .background_valid(background_valid)
    );

    integer signed hist_i [0:511];
    integer signed hist_q [0:511];
    integer sample_counter = 0;
    integer lane;
    integer index_ref;
    integer index_target;
    integer signed ref_i_value;
    integer signed ref_q_value;
    integer signed target_i_value;
    integer signed target_q_value;
    integer signed echo_i_value;
    integer signed echo_q_value;

    function integer signed sign16;
        input [15:0] value;
        begin
            sign16 = $signed(value);
        end
    endfunction

    function [15:0] clip16;
        input integer signed value;
        integer signed clipped;
        begin
            if (value > 32767)
                clipped = 32767;
            else if (value < -32768)
                clipped = -32768;
            else
                clipped = value;
            clip16 = clipped[15:0];
        end
    endfunction

    always @(posedge clk) begin
        for (lane = 0; lane < 4; lane = lane + 1) begin
            hist_i[(sample_counter + lane) & 511] =
                sign16(dac_data[lane*32 +: 16]);
            hist_q[(sample_counter + lane) & 511] =
                sign16(dac_data[lane*32 + 16 +: 16]);

            index_ref = (sample_counter + lane - REF_DELAY) & 511;
            index_target = (sample_counter + lane - REF_DELAY - TARGET_LAG) & 511;
            ref_i_value = hist_i[index_ref];
            ref_q_value = hist_q[index_ref];
            target_i_value = hist_i[index_target];
            target_q_value = hist_q[index_target];
            echo_i_value = ref_i_value >>> 2;
            echo_q_value = ref_q_value >>> 2;
            if (target_enable) begin
                echo_i_value = echo_i_value + (target_i_value >>> 1);
                echo_q_value = echo_q_value + (target_q_value >>> 1);
            end

            ref_i[lane*16 +: 16] <= clip16(ref_i_value);
            ref_q[lane*16 +: 16] <= clip16(ref_q_value);
            echo_i[lane*16 +: 16] <= clip16(echo_i_value);
            echo_q[lane*16 +: 16] <= clip16(echo_q_value);
        end
        sample_counter <= sample_counter + 4;
    end

    task send_command(input [31:0] command_word);
        begin
            @(posedge clk);
            ctrl_data <= command_word;
            ctrl_valid <= 1'b1;
            @(posedge clk);
            ctrl_valid <= 1'b0;
            ctrl_data <= 32'd0;
        end
    endtask

    integer packet_word = 0;
    integer packet_count = 0;
    reg [15:0] observed_lag = 16'hffff;
    reg [31:0] observed_flags = 32'd0;

    always @(posedge clk) begin
        if (result_valid && result_ready) begin
            case (packet_word)
                0: if (result_data !== 32'h524e4731) $fatal(1, "bad result magic");
                1: observed_lag <= result_data[15:0];
                5: observed_flags <= result_data;
            endcase
            if (result_last) begin
                packet_word <= 0;
                packet_count <= packet_count + 1;
            end else begin
                packet_word <= packet_word + 1;
            end
        end
    end

    integer timeout;
    initial begin
        for (lane = 0; lane < 512; lane = lane + 1) begin
            hist_i[lane] = 0;
            hist_q[lane] = 0;
        end

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        send_command(32'h42474341);
        send_command(32'h524e4701);

        timeout = 0;
        while (packet_count < 1 && timeout < 20000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (packet_count < 1) $fatal(1, "background calibration timed out");
        if (!background_valid) $fatal(1, "background calibration flag not set");

        target_enable <= 1'b1;
        timeout = 0;
        while (packet_count < 2 && timeout < 20000) begin
            @(posedge clk);
            timeout = timeout + 1;
        end
        if (packet_count < 2) $fatal(1, "target measurement timed out");
        if (observed_lag < TARGET_LAG-1 || observed_lag > TARGET_LAG+1)
            $fatal(1, "expected target lag near %0d, got %0d", TARGET_LAG, observed_lag);

        $display("PASS: calibrated background and detected target lag %0d", observed_lag);
        $finish;
    end

endmodule
