`timescale 1ns / 1ps

// Four-lane memory-polynomial DPD datapath.
//
// Sample packing (earliest sample in the least-significant word):
//   TDATA[ 31:  0] = {Q0, I0}
//   TDATA[ 63: 32] = {Q1, I1}
//   TDATA[ 95: 64] = {Q2, I2}
//   TDATA[127: 96] = {Q3, I3}
//
// The coefficient memories contain the precomputed complex gain
//
//   h_m(|x|^2) = sum_k c[k,m] * |x|^(2k)
//
// for one memory tap.  Each entry is packed as {gain_q, gain_i}, with both
// components represented as signed 16-bit values with FRAC_BITS fractional
// bits.  The four physical copies per tap provide the 16 simultaneous reads
// needed for four output samples and four memory taps each cycle.
//
// Coefficient writes use the independent cfg_clk port.  Software should write
// the inactive bank and then issue commit_pulse in the sample clock domain.
module dpd_mp_4lane_core #(
    parameter integer LANES      = 4,
    parameter integer TAPS       = 4,
    parameter integer ADDR_WIDTH = 12,
    parameter integer FRAC_BITS  = 14
)(
    input  wire                         axis_clk,
    input  wire                         axis_resetn,

    input  wire [LANES*32-1:0]          s_axis_tdata,
    input  wire                         s_axis_tvalid,
    output reg  [LANES*32-1:0]          m_axis_tdata,
    output reg                          m_axis_tvalid,

    input  wire                         dpd_enable,
    input  wire                         commit_pulse,
    input  wire                         clear_clip_pulse,
    output reg                          active_bank,
    output wire [31:0]                  clip_count_gray,

    input  wire                         cfg_clk,
    input  wire                         cfg_we,
    input  wire                         cfg_bank,
    input  wire [$clog2(TAPS)-1:0]       cfg_tap,
    input  wire [ADDR_WIDTH-1:0]         cfg_addr,
    input  wire [31:0]                  cfg_wdata
);

    localparam integer HISTORY = TAPS - 1;
    localparam integer PROD_W  = 33;
    localparam integer SUM_W   = PROD_W + $clog2(TAPS);

    integer lane_i;
    integer tap_i;

    wire signed [15:0] current_i [0:LANES-1];
    wire signed [15:0] current_q [0:LANES-1];
    wire [ADDR_WIDTH-1:0] current_addr [0:LANES-1];

    reg signed [15:0] history_i [0:HISTORY-1];
    reg signed [15:0] history_q [0:HISTORY-1];
    reg [ADDR_WIDTH-1:0] history_addr [0:HISTORY-1];

    reg signed [15:0] selected_i [0:LANES-1][0:TAPS-1];
    reg signed [15:0] selected_q [0:LANES-1][0:TAPS-1];
    reg [ADDR_WIDTH-1:0] selected_addr [0:LANES-1][0:TAPS-1];

    reg signed [15:0] sample_i_s1 [0:LANES-1][0:TAPS-1];
    reg signed [15:0] sample_q_s1 [0:LANES-1][0:TAPS-1];
    reg signed [15:0] coeff_i_s1  [0:LANES-1][0:TAPS-1];
    reg signed [15:0] coeff_q_s1  [0:LANES-1][0:TAPS-1];

    reg signed [PROD_W-1:0] product_i_s2 [0:LANES-1][0:TAPS-1];
    reg signed [PROD_W-1:0] product_q_s2 [0:LANES-1][0:TAPS-1];

    reg signed [SUM_W-1:0] sum_i_comb [0:LANES-1];
    reg signed [SUM_W-1:0] sum_q_comb [0:LANES-1];
    reg signed [SUM_W-1:0] scaled_i_comb [0:LANES-1];
    reg signed [SUM_W-1:0] scaled_q_comb [0:LANES-1];
    reg signed [15:0] quant_i_comb [0:LANES-1];
    reg signed [15:0] quant_q_comb [0:LANES-1];
    reg [LANES*32-1:0] dpd_data_comb;
    reg clip_any_comb;

    reg [LANES*32-1:0] bypass_s1;
    reg [LANES*32-1:0] bypass_s2;
    reg enable_s1;
    reg enable_s2;
    reg valid_s1;
    reg valid_s2;
    reg [31:0] clip_count_bin;

    genvar lane_g;
    genvar tap_g;

    function automatic [ADDR_WIDTH-1:0] magnitude_address;
        input signed [15:0] value_i;
        input signed [15:0] value_q;
        reg signed [31:0] square_i_signed;
        reg signed [31:0] square_q_signed;
        reg [32:0] power_sum;
        begin
            square_i_signed = value_i * value_i;
            square_q_signed = value_q * value_q;
            power_sum = {1'b0, $unsigned(square_i_signed)}
                      + {1'b0, $unsigned(square_q_signed)};

            // The address represents the most significant ADDR_WIDTH bits of
            // the normalized magnitude squared.  Saturate if I and Q together
            // exceed the signed full-scale circle.
            if (power_sum[32] || power_sum[31])
                magnitude_address = {ADDR_WIDTH{1'b1}};
            else
                magnitude_address = power_sum[30 -: ADDR_WIDTH];
        end
    endfunction

    function automatic signed [SUM_W-1:0] rounded_shift;
        input signed [SUM_W-1:0] value;
        reg signed [SUM_W-1:0] magnitude;
        reg signed [SUM_W-1:0] rounded_magnitude;
        begin
            if (value < 0) begin
                magnitude = -value;
                rounded_magnitude = magnitude + ({{(SUM_W-1){1'b0}}, 1'b1} << (FRAC_BITS-1));
                rounded_shift = -(rounded_magnitude >>> FRAC_BITS);
            end else begin
                rounded_shift = (value + ({{(SUM_W-1){1'b0}}, 1'b1} << (FRAC_BITS-1))) >>> FRAC_BITS;
            end
        end
    endfunction

    generate
        for (lane_g = 0; lane_g < LANES; lane_g = lane_g + 1) begin : g_unpack
            assign current_i[lane_g] = $signed(s_axis_tdata[lane_g*32 +: 16]);
            assign current_q[lane_g] = $signed(s_axis_tdata[lane_g*32+16 +: 16]);
            assign current_addr[lane_g] = magnitude_address(current_i[lane_g], current_q[lane_g]);
        end
    endgenerate

    // Select current-beat or history samples for every output lane/tap pair.
    always @(*) begin
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                if (tap_i <= lane_i) begin
                    selected_i[lane_i][tap_i] = current_i[lane_i-tap_i];
                    selected_q[lane_i][tap_i] = current_q[lane_i-tap_i];
                    selected_addr[lane_i][tap_i] = current_addr[lane_i-tap_i];
                end else begin
                    selected_i[lane_i][tap_i] = history_i[tap_i-lane_i-1];
                    selected_q[lane_i][tap_i] = history_q[tap_i-lane_i-1];
                    selected_addr[lane_i][tap_i] = history_addr[tap_i-lane_i-1];
                end
            end
        end
    end

    // Replicated, dual-clock, simple-dual-port coefficient memories.
    generate
        for (lane_g = 0; lane_g < LANES; lane_g = lane_g + 1) begin : g_lane_mem
            for (tap_g = 0; tap_g < TAPS; tap_g = tap_g + 1) begin : g_tap_mem
                (* ram_style = "block" *) reg [31:0] coefficient_bank0 [0:(1<<ADDR_WIDTH)-1];
                (* ram_style = "block" *) reg [31:0] coefficient_bank1 [0:(1<<ADDR_WIDTH)-1];

                always @(posedge cfg_clk) begin
                    if (cfg_we && (cfg_tap == tap_g[$clog2(TAPS)-1:0])) begin
                        if (cfg_bank)
                            coefficient_bank1[cfg_addr] <= cfg_wdata;
                        else
                            coefficient_bank0[cfg_addr] <= cfg_wdata;
                    end
                end

                always @(posedge axis_clk) begin
                    if (!axis_resetn) begin
                        sample_i_s1[lane_g][tap_g] <= 16'sd0;
                        sample_q_s1[lane_g][tap_g] <= 16'sd0;
                        coeff_i_s1[lane_g][tap_g]  <= 16'sd0;
                        coeff_q_s1[lane_g][tap_g]  <= 16'sd0;
                    end else if (s_axis_tvalid) begin
                        sample_i_s1[lane_g][tap_g] <= selected_i[lane_g][tap_g];
                        sample_q_s1[lane_g][tap_g] <= selected_q[lane_g][tap_g];
                        if (active_bank) begin
                            coeff_i_s1[lane_g][tap_g] <= $signed(coefficient_bank1[selected_addr[lane_g][tap_g]][15:0]);
                            coeff_q_s1[lane_g][tap_g] <= $signed(coefficient_bank1[selected_addr[lane_g][tap_g]][31:16]);
                        end else begin
                            coeff_i_s1[lane_g][tap_g] <= $signed(coefficient_bank0[selected_addr[lane_g][tap_g]][15:0]);
                            coeff_q_s1[lane_g][tap_g] <= $signed(coefficient_bank0[selected_addr[lane_g][tap_g]][31:16]);
                        end
                    end
                end
            end
        end
    endgenerate

    // Complex multipliers.  Keeping the four real products explicit gives
    // predictable DSP48 inference and matches the resource model in the paper.
    generate
        for (lane_g = 0; lane_g < LANES; lane_g = lane_g + 1) begin : g_lane_mult
            for (tap_g = 0; tap_g < TAPS; tap_g = tap_g + 1) begin : g_tap_mult
                wire signed [31:0] mul_i_ci = sample_i_s1[lane_g][tap_g] * coeff_i_s1[lane_g][tap_g];
                wire signed [31:0] mul_q_cq = sample_q_s1[lane_g][tap_g] * coeff_q_s1[lane_g][tap_g];
                wire signed [31:0] mul_i_cq = sample_i_s1[lane_g][tap_g] * coeff_q_s1[lane_g][tap_g];
                wire signed [31:0] mul_q_ci = sample_q_s1[lane_g][tap_g] * coeff_i_s1[lane_g][tap_g];

                always @(posedge axis_clk) begin
                    if (!axis_resetn) begin
                        product_i_s2[lane_g][tap_g] <= {PROD_W{1'b0}};
                        product_q_s2[lane_g][tap_g] <= {PROD_W{1'b0}};
                    end else if (valid_s1) begin
                        product_i_s2[lane_g][tap_g] <=
                            $signed({mul_i_ci[31], mul_i_ci}) - $signed({mul_q_cq[31], mul_q_cq});
                        product_q_s2[lane_g][tap_g] <=
                            $signed({mul_i_cq[31], mul_i_cq}) + $signed({mul_q_ci[31], mul_q_ci});
                    end
                end
            end
        end
    endgenerate

    // Sum the memory taps and return to the 16-bit sample format.
    always @(*) begin
        dpd_data_comb = {LANES*32{1'b0}};
        clip_any_comb = 1'b0;

        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            sum_i_comb[lane_i] = {SUM_W{1'b0}};
            sum_q_comb[lane_i] = {SUM_W{1'b0}};
            for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                sum_i_comb[lane_i] = sum_i_comb[lane_i]
                    + {{(SUM_W-PROD_W){product_i_s2[lane_i][tap_i][PROD_W-1]}}, product_i_s2[lane_i][tap_i]};
                sum_q_comb[lane_i] = sum_q_comb[lane_i]
                    + {{(SUM_W-PROD_W){product_q_s2[lane_i][tap_i][PROD_W-1]}}, product_q_s2[lane_i][tap_i]};
            end

            scaled_i_comb[lane_i] = rounded_shift(sum_i_comb[lane_i]);
            scaled_q_comb[lane_i] = rounded_shift(sum_q_comb[lane_i]);

            if (scaled_i_comb[lane_i] > 32767) begin
                quant_i_comb[lane_i] = 16'sd32767;
                clip_any_comb = 1'b1;
            end else if (scaled_i_comb[lane_i] < -32768) begin
                quant_i_comb[lane_i] = -16'sd32768;
                clip_any_comb = 1'b1;
            end else begin
                quant_i_comb[lane_i] = scaled_i_comb[lane_i][15:0];
            end

            if (scaled_q_comb[lane_i] > 32767) begin
                quant_q_comb[lane_i] = 16'sd32767;
                clip_any_comb = 1'b1;
            end else if (scaled_q_comb[lane_i] < -32768) begin
                quant_q_comb[lane_i] = -16'sd32768;
                clip_any_comb = 1'b1;
            end else begin
                quant_q_comb[lane_i] = scaled_q_comb[lane_i][15:0];
            end

            dpd_data_comb[lane_i*32 +: 16] = quant_i_comb[lane_i];
            dpd_data_comb[lane_i*32+16 +: 16] = quant_q_comb[lane_i];
        end
    end

    // Valid/mode pipeline, history maintenance, bank commit and status.
    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            active_bank  <= 1'b0;
            bypass_s1    <= {LANES*32{1'b0}};
            bypass_s2    <= {LANES*32{1'b0}};
            enable_s1    <= 1'b0;
            enable_s2    <= 1'b0;
            valid_s1     <= 1'b0;
            valid_s2     <= 1'b0;
            m_axis_tdata <= {LANES*32{1'b0}};
            m_axis_tvalid<= 1'b0;
            clip_count_bin <= 32'd0;
            for (lane_i = 0; lane_i < HISTORY; lane_i = lane_i + 1) begin
                history_i[lane_i] <= 16'sd0;
                history_q[lane_i] <= 16'sd0;
                history_addr[lane_i] <= {ADDR_WIDTH{1'b0}};
            end
        end else begin
            if (commit_pulse)
                active_bank <= ~active_bank;

            bypass_s1 <= s_axis_tdata;
            bypass_s2 <= bypass_s1;
            enable_s1 <= dpd_enable;
            enable_s2 <= enable_s1;
            valid_s1  <= s_axis_tvalid;
            valid_s2  <= valid_s1;

            m_axis_tvalid <= valid_s2;
            if (valid_s2)
                m_axis_tdata <= enable_s2 ? dpd_data_comb : bypass_s2;

            if (clear_clip_pulse)
                clip_count_bin <= 32'd0;
            else if (valid_s2 && enable_s2 && clip_any_comb)
                clip_count_bin <= clip_count_bin + 1'b1;

            if (s_axis_tvalid) begin
                // Four new samples arrive every cycle, so only the final three
                // are needed as history for lane 0 of the next beat.
                for (lane_i = 0; lane_i < HISTORY; lane_i = lane_i + 1) begin
                    history_i[lane_i] <= current_i[LANES-1-lane_i];
                    history_q[lane_i] <= current_q[LANES-1-lane_i];
                    history_addr[lane_i] <= current_addr[LANES-1-lane_i];
                end
            end
        end
    end

    assign clip_count_gray = (clip_count_bin >> 1) ^ clip_count_bin;

endmodule
