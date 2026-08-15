`timescale 1ns / 1ps

// Four-lane memory-polynomial DPD datapath.
//
// All coefficient-memory accesses occur in axis_clk.  The AXI wrapper moves
// coefficient write commands into this clock domain before asserting cfg_we.
// Each lane/tap/bank has a dedicated synchronous Block RAM read port so that
// four samples x four taps can be evaluated every fabric clock.
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
    output reg  [31:0]                  clip_count_gray,

    // Coefficient write command, synchronous to axis_clk.
    input  wire                         cfg_we,
    input  wire                         cfg_bank,
    input  wire [$clog2(TAPS)-1:0]      cfg_tap,
    input  wire [ADDR_WIDTH-1:0]        cfg_addr,
    input  wire [31:0]                  cfg_wdata
);

    localparam integer HISTORY = TAPS - 1;
    localparam integer PROD_W  = 33;
    localparam integer SUM_W   = PROD_W + $clog2(TAPS);

    integer lane_i;
    integer tap_i;

    wire signed [15:0] current_i [0:LANES-1];
    wire signed [15:0] current_q [0:LANES-1];

    reg signed [15:0] history_i [0:HISTORY-1];
    reg signed [15:0] history_q [0:HISTORY-1];

    reg signed [15:0] selected_i [0:LANES-1][0:TAPS-1];
    reg signed [15:0] selected_q [0:LANES-1][0:TAPS-1];

    // S0: input/history selection.
    reg signed [15:0] sample_i_s0 [0:LANES-1][0:TAPS-1];
    reg signed [15:0] sample_q_s0 [0:LANES-1][0:TAPS-1];

    // S1: magnitude-address calculation.
    reg signed [15:0] sample_i_s1 [0:LANES-1][0:TAPS-1];
    reg signed [15:0] sample_q_s1 [0:LANES-1][0:TAPS-1];
    reg [ADDR_WIDTH-1:0] coefficient_addr_s1 [0:LANES-1][0:TAPS-1];

    // S2: synchronous coefficient-memory read alignment.
    reg signed [15:0] sample_i_s2 [0:LANES-1][0:TAPS-1];
    reg signed [15:0] sample_q_s2 [0:LANES-1][0:TAPS-1];
    wire [31:0] coefficient_bank0_s2 [0:LANES-1][0:TAPS-1];
    wire [31:0] coefficient_bank1_s2 [0:LANES-1][0:TAPS-1];

    // S3: four registered real multiplications per complex product.
    reg signed [31:0] multiply_ii_s3 [0:LANES-1][0:TAPS-1];
    reg signed [31:0] multiply_qq_s3 [0:LANES-1][0:TAPS-1];
    reg signed [31:0] multiply_iq_s3 [0:LANES-1][0:TAPS-1];
    reg signed [31:0] multiply_qi_s3 [0:LANES-1][0:TAPS-1];

    // S4: complex add/subtract.
    reg signed [PROD_W-1:0] product_i_s4 [0:LANES-1][0:TAPS-1];
    reg signed [PROD_W-1:0] product_q_s4 [0:LANES-1][0:TAPS-1];

    // S5: tap reduction.
    reg signed [SUM_W-1:0] sum_i_s5 [0:LANES-1];
    reg signed [SUM_W-1:0] sum_q_s5 [0:LANES-1];
    reg signed [SUM_W-1:0] product_sum_i_comb [0:LANES-1];
    reg signed [SUM_W-1:0] product_sum_q_comb [0:LANES-1];

    // S6: quantization/output.
    reg signed [SUM_W-1:0] scaled_i_comb [0:LANES-1];
    reg signed [SUM_W-1:0] scaled_q_comb [0:LANES-1];
    reg signed [15:0] quant_i_comb [0:LANES-1];
    reg signed [15:0] quant_q_comb [0:LANES-1];
    reg [LANES*32-1:0] dpd_data_comb;
    reg clip_any_comb;

    reg [LANES*32-1:0] bypass_s0;
    reg [LANES*32-1:0] bypass_s1;
    reg [LANES*32-1:0] bypass_s2;
    reg [LANES*32-1:0] bypass_s3;
    reg [LANES*32-1:0] bypass_s4;
    reg [LANES*32-1:0] bypass_s5;
    reg enable_s0;
    reg enable_s1;
    reg enable_s2;
    reg enable_s3;
    reg enable_s4;
    reg enable_s5;
    reg valid_s0;
    reg valid_s1;
    reg valid_s2;
    reg valid_s3;
    reg valid_s4;
    reg valid_s5;
    reg bank_s0;
    reg bank_s1;
    reg bank_s2;
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
                rounded_magnitude = magnitude
                    + ({{(SUM_W-1){1'b0}}, 1'b1} << (FRAC_BITS-1));
                rounded_shift = -(rounded_magnitude >>> FRAC_BITS);
            end else begin
                rounded_shift = (value
                    + ({{(SUM_W-1){1'b0}}, 1'b1} << (FRAC_BITS-1)))
                    >>> FRAC_BITS;
            end
        end
    endfunction

    generate
        for (lane_g = 0; lane_g < LANES; lane_g = lane_g + 1) begin : g_unpack
            assign current_i[lane_g] =
                $signed(s_axis_tdata[lane_g*32 +: 16]);
            assign current_q[lane_g] =
                $signed(s_axis_tdata[lane_g*32+16 +: 16]);
        end
    endgenerate

    always @(*) begin
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                if (tap_i <= lane_i) begin
                    selected_i[lane_i][tap_i] = current_i[lane_i-tap_i];
                    selected_q[lane_i][tap_i] = current_q[lane_i-tap_i];
                end else begin
                    selected_i[lane_i][tap_i] =
                        history_i[tap_i-lane_i-1];
                    selected_q[lane_i][tap_i] =
                        history_q[tap_i-lane_i-1];
                end
            end
        end
    end

    // Explicit synchronous Block RAMs.  Replication supplies one coefficient
    // read per lane/tap while writes are broadcast to the four lane copies.
    generate
        for (lane_g = 0; lane_g < LANES; lane_g = lane_g + 1) begin : g_lane_mem
            for (tap_g = 0; tap_g < TAPS; tap_g = tap_g + 1) begin : g_tap_mem
                wire write_bank0 = cfg_we && !cfg_bank && (cfg_tap == tap_g);
                wire write_bank1 = cfg_we &&  cfg_bank && (cfg_tap == tap_g);

                xpm_memory_sdpram #(
                    .ADDR_WIDTH_A            (ADDR_WIDTH),
                    .ADDR_WIDTH_B            (ADDR_WIDTH),
                    .AUTO_SLEEP_TIME         (0),
                    .BYTE_WRITE_WIDTH_A      (32),
                    .CLOCKING_MODE           ("common_clock"),
                    .ECC_MODE                ("no_ecc"),
                    .MEMORY_INIT_FILE        ("none"),
                    .MEMORY_INIT_PARAM       ("0"),
                    .MEMORY_OPTIMIZATION     ("true"),
                    .MEMORY_PRIMITIVE        ("block"),
                    .MEMORY_SIZE             ((1 << ADDR_WIDTH) * 32),
                    .MESSAGE_CONTROL         (0),
                    .READ_DATA_WIDTH_B       (32),
                    .READ_LATENCY_B          (1),
                    .READ_RESET_VALUE_B      ("0"),
                    .USE_EMBEDDED_CONSTRAINT (0),
                    .USE_MEM_INIT            (0),
                    .WAKEUP_TIME             ("disable_sleep"),
                    .WRITE_DATA_WIDTH_A      (32),
                    .WRITE_MODE_B            ("no_change")
                ) u_coefficient_bank0 (
                    .dbiterrb       (),
                    .doutb          (coefficient_bank0_s2[lane_g][tap_g]),
                    .sbiterrb       (),
                    .addra          (cfg_addr),
                    .addrb          (coefficient_addr_s1[lane_g][tap_g]),
                    .clka           (axis_clk),
                    .clkb           (axis_clk),
                    .dina           (cfg_wdata),
                    .ena            (write_bank0),
                    .enb            (valid_s1),
                    .injectdbiterra (1'b0),
                    .injectsbiterra (1'b0),
                    .regceb         (1'b1),
                    .rstb           (!axis_resetn),
                    .sleep          (1'b0),
                    .wea            (write_bank0)
                );

                xpm_memory_sdpram #(
                    .ADDR_WIDTH_A            (ADDR_WIDTH),
                    .ADDR_WIDTH_B            (ADDR_WIDTH),
                    .AUTO_SLEEP_TIME         (0),
                    .BYTE_WRITE_WIDTH_A      (32),
                    .CLOCKING_MODE           ("common_clock"),
                    .ECC_MODE                ("no_ecc"),
                    .MEMORY_INIT_FILE        ("none"),
                    .MEMORY_INIT_PARAM       ("0"),
                    .MEMORY_OPTIMIZATION     ("true"),
                    .MEMORY_PRIMITIVE        ("block"),
                    .MEMORY_SIZE             ((1 << ADDR_WIDTH) * 32),
                    .MESSAGE_CONTROL         (0),
                    .READ_DATA_WIDTH_B       (32),
                    .READ_LATENCY_B          (1),
                    .READ_RESET_VALUE_B      ("0"),
                    .USE_EMBEDDED_CONSTRAINT (0),
                    .USE_MEM_INIT            (0),
                    .WAKEUP_TIME             ("disable_sleep"),
                    .WRITE_DATA_WIDTH_A      (32),
                    .WRITE_MODE_B            ("no_change")
                ) u_coefficient_bank1 (
                    .dbiterrb       (),
                    .doutb          (coefficient_bank1_s2[lane_g][tap_g]),
                    .sbiterrb       (),
                    .addra          (cfg_addr),
                    .addrb          (coefficient_addr_s1[lane_g][tap_g]),
                    .clka           (axis_clk),
                    .clkb           (axis_clk),
                    .dina           (cfg_wdata),
                    .ena            (write_bank1),
                    .enb            (valid_s1),
                    .injectdbiterra (1'b0),
                    .injectsbiterra (1'b0),
                    .regceb         (1'b1),
                    .rstb           (!axis_resetn),
                    .sleep          (1'b0),
                    .wea            (write_bank1)
                );
            end
        end
    endgenerate

    // Balanced tap reduction from registered complex products.
    always @(*) begin
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            product_sum_i_comb[lane_i] =
                $signed(product_i_s4[lane_i][0])
                + $signed(product_i_s4[lane_i][1])
                + $signed(product_i_s4[lane_i][2])
                + $signed(product_i_s4[lane_i][3]);
            product_sum_q_comb[lane_i] =
                $signed(product_q_s4[lane_i][0])
                + $signed(product_q_s4[lane_i][1])
                + $signed(product_q_s4[lane_i][2])
                + $signed(product_q_s4[lane_i][3]);
        end
    end

    always @(*) begin
        dpd_data_comb = {LANES*32{1'b0}};
        clip_any_comb = 1'b0;
        for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
            scaled_i_comb[lane_i] = rounded_shift(sum_i_s5[lane_i]);
            scaled_q_comb[lane_i] = rounded_shift(sum_q_s5[lane_i]);

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

    always @(posedge axis_clk) begin
        if (!axis_resetn) begin
            active_bank   <= 1'b0;
            m_axis_tdata  <= {LANES*32{1'b0}};
            m_axis_tvalid <= 1'b0;
            bypass_s0 <= {LANES*32{1'b0}};
            bypass_s1 <= {LANES*32{1'b0}};
            bypass_s2 <= {LANES*32{1'b0}};
            bypass_s3 <= {LANES*32{1'b0}};
            bypass_s4 <= {LANES*32{1'b0}};
            bypass_s5 <= {LANES*32{1'b0}};
            enable_s0 <= 1'b0;
            enable_s1 <= 1'b0;
            enable_s2 <= 1'b0;
            enable_s3 <= 1'b0;
            enable_s4 <= 1'b0;
            enable_s5 <= 1'b0;
            valid_s0 <= 1'b0;
            valid_s1 <= 1'b0;
            valid_s2 <= 1'b0;
            valid_s3 <= 1'b0;
            valid_s4 <= 1'b0;
            valid_s5 <= 1'b0;
            bank_s0 <= 1'b0;
            bank_s1 <= 1'b0;
            bank_s2 <= 1'b0;
            clip_count_bin <= 32'd0;
            clip_count_gray <= 32'd0;
            for (lane_i = 0; lane_i < HISTORY; lane_i = lane_i + 1) begin
                history_i[lane_i] <= 16'sd0;
                history_q[lane_i] <= 16'sd0;
            end
            for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                sum_i_s5[lane_i] <= {SUM_W{1'b0}};
                sum_q_s5[lane_i] <= {SUM_W{1'b0}};
                for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                    sample_i_s0[lane_i][tap_i] <= 16'sd0;
                    sample_q_s0[lane_i][tap_i] <= 16'sd0;
                    sample_i_s1[lane_i][tap_i] <= 16'sd0;
                    sample_q_s1[lane_i][tap_i] <= 16'sd0;
                    sample_i_s2[lane_i][tap_i] <= 16'sd0;
                    sample_q_s2[lane_i][tap_i] <= 16'sd0;
                    coefficient_addr_s1[lane_i][tap_i] <= {ADDR_WIDTH{1'b0}};
                    multiply_ii_s3[lane_i][tap_i] <= 32'sd0;
                    multiply_qq_s3[lane_i][tap_i] <= 32'sd0;
                    multiply_iq_s3[lane_i][tap_i] <= 32'sd0;
                    multiply_qi_s3[lane_i][tap_i] <= 32'sd0;
                    product_i_s4[lane_i][tap_i] <= {PROD_W{1'b0}};
                    product_q_s4[lane_i][tap_i] <= {PROD_W{1'b0}};
                end
            end
        end else begin
            // Register the Gray-code value in the source clock domain before
            // it enters the AXI-domain synchronizer.  This prevents the XOR
            // conversion logic from creating combinational CDC paths.
            clip_count_gray <= (clip_count_bin >> 1) ^ clip_count_bin;

            if (commit_pulse)
                active_bank <= ~active_bank;

            bypass_s0 <= s_axis_tdata;
            bypass_s1 <= bypass_s0;
            bypass_s2 <= bypass_s1;
            bypass_s3 <= bypass_s2;
            bypass_s4 <= bypass_s3;
            bypass_s5 <= bypass_s4;
            enable_s0 <= dpd_enable;
            enable_s1 <= enable_s0;
            enable_s2 <= enable_s1;
            enable_s3 <= enable_s2;
            enable_s4 <= enable_s3;
            enable_s5 <= enable_s4;
            valid_s0 <= s_axis_tvalid;
            valid_s1 <= valid_s0;
            valid_s2 <= valid_s1;
            valid_s3 <= valid_s2;
            valid_s4 <= valid_s3;
            valid_s5 <= valid_s4;
            bank_s0 <= active_bank;
            bank_s1 <= bank_s0;
            bank_s2 <= bank_s1;

            if (s_axis_tvalid) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                        sample_i_s0[lane_i][tap_i] <= selected_i[lane_i][tap_i];
                        sample_q_s0[lane_i][tap_i] <= selected_q[lane_i][tap_i];
                    end
                end
                for (lane_i = 0; lane_i < HISTORY; lane_i = lane_i + 1) begin
                    history_i[lane_i] <= current_i[LANES-1-lane_i];
                    history_q[lane_i] <= current_q[LANES-1-lane_i];
                end
            end

            if (valid_s0) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                        sample_i_s1[lane_i][tap_i] <= sample_i_s0[lane_i][tap_i];
                        sample_q_s1[lane_i][tap_i] <= sample_q_s0[lane_i][tap_i];
                        coefficient_addr_s1[lane_i][tap_i] <=
                            magnitude_address(sample_i_s0[lane_i][tap_i],
                                              sample_q_s0[lane_i][tap_i]);
                    end
                end
            end

            if (valid_s1) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                        sample_i_s2[lane_i][tap_i] <= sample_i_s1[lane_i][tap_i];
                        sample_q_s2[lane_i][tap_i] <= sample_q_s1[lane_i][tap_i];
                    end
                end
            end

            if (valid_s2) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                        if (bank_s2) begin
                            multiply_ii_s3[lane_i][tap_i] <=
                                $signed(sample_i_s2[lane_i][tap_i])
                                * $signed(coefficient_bank1_s2[lane_i][tap_i][15:0]);
                            multiply_qq_s3[lane_i][tap_i] <=
                                $signed(sample_q_s2[lane_i][tap_i])
                                * $signed(coefficient_bank1_s2[lane_i][tap_i][31:16]);
                            multiply_iq_s3[lane_i][tap_i] <=
                                $signed(sample_i_s2[lane_i][tap_i])
                                * $signed(coefficient_bank1_s2[lane_i][tap_i][31:16]);
                            multiply_qi_s3[lane_i][tap_i] <=
                                $signed(sample_q_s2[lane_i][tap_i])
                                * $signed(coefficient_bank1_s2[lane_i][tap_i][15:0]);
                        end else begin
                            multiply_ii_s3[lane_i][tap_i] <=
                                $signed(sample_i_s2[lane_i][tap_i])
                                * $signed(coefficient_bank0_s2[lane_i][tap_i][15:0]);
                            multiply_qq_s3[lane_i][tap_i] <=
                                $signed(sample_q_s2[lane_i][tap_i])
                                * $signed(coefficient_bank0_s2[lane_i][tap_i][31:16]);
                            multiply_iq_s3[lane_i][tap_i] <=
                                $signed(sample_i_s2[lane_i][tap_i])
                                * $signed(coefficient_bank0_s2[lane_i][tap_i][31:16]);
                            multiply_qi_s3[lane_i][tap_i] <=
                                $signed(sample_q_s2[lane_i][tap_i])
                                * $signed(coefficient_bank0_s2[lane_i][tap_i][15:0]);
                        end
                    end
                end
            end

            if (valid_s3) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    for (tap_i = 0; tap_i < TAPS; tap_i = tap_i + 1) begin
                        product_i_s4[lane_i][tap_i] <=
                            $signed({multiply_ii_s3[lane_i][tap_i][31],
                                     multiply_ii_s3[lane_i][tap_i]})
                            - $signed({multiply_qq_s3[lane_i][tap_i][31],
                                       multiply_qq_s3[lane_i][tap_i]});
                        product_q_s4[lane_i][tap_i] <=
                            $signed({multiply_iq_s3[lane_i][tap_i][31],
                                     multiply_iq_s3[lane_i][tap_i]})
                            + $signed({multiply_qi_s3[lane_i][tap_i][31],
                                       multiply_qi_s3[lane_i][tap_i]});
                    end
                end
            end

            if (valid_s4) begin
                for (lane_i = 0; lane_i < LANES; lane_i = lane_i + 1) begin
                    sum_i_s5[lane_i] <= product_sum_i_comb[lane_i];
                    sum_q_s5[lane_i] <= product_sum_q_comb[lane_i];
                end
            end

            m_axis_tvalid <= valid_s5;
            if (valid_s5)
                m_axis_tdata <= enable_s5 ? dpd_data_comb : bypass_s5;

            if (clear_clip_pulse)
                clip_count_bin <= 32'd0;
            else if (valid_s5 && enable_s5 && clip_any_comb)
                clip_count_bin <= clip_count_bin + 1'b1;
        end
    end

endmodule
