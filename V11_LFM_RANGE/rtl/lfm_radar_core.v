`timescale 1ns / 1ps

// V11 short-range LFM radar core.
//
// Capture storage and correlation background storage use synchronous block-RAM
// templates.  No memory is written from the asynchronous-reset control block;
// this is required for reliable BRAM inference in Vivado 2020.2.
module lfm_radar_core #(
    parameter integer CLK_FREQ_HZ       = 184_320_000,
    parameter integer PRF_HZ            = 10_000,
    parameter integer PULSE_SAMPLES     = 4096,
    parameter integer CAPTURE_SAMPLES   = 8192,
    parameter integer MAX_LAG           = 128,
    parameter         ROM_FILE          = "lfm_400mhz_4096.mem"
) (
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME clk, ASSOCIATED_BUSIF m0_axis:m1_axis:echo_i_axis:echo_q_axis:ref_i_axis:ref_q_axis:s_axis_ctrl:m_axis_result, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire         clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME rst_n, POLARITY ACTIVE_LOW" *)
    input  wire         rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_ctrl TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axis_ctrl, FREQ_HZ 184320000, HAS_TLAST 1" *)
    input  wire [31:0]  s_axis_ctrl_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_ctrl TVALID" *)
    input  wire         s_axis_ctrl_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_ctrl TREADY" *)
    output wire         s_axis_ctrl_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_ctrl TLAST" *)
    input  wire         s_axis_ctrl_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_result TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis_result, FREQ_HZ 184320000, HAS_TLAST 1" *)
    output reg  [31:0]  m_axis_result_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_result TVALID" *)
    output reg          m_axis_result_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_result TREADY" *)
    input  wire         m_axis_result_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_result TLAST" *)
    output reg          m_axis_result_tlast,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m0_axis, FREQ_HZ 184320000" *)
    output wire [127:0] m0_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m0_axis TVALID" *)
    output wire         m0_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m1_axis, FREQ_HZ 184320000" *)
    output wire [127:0] m1_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m1_axis TVALID" *)
    output wire         m1_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 echo_i_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME echo_i_axis, FREQ_HZ 184320000" *)
    input  wire [63:0]  echo_i_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 echo_i_axis TVALID" *)
    input  wire         echo_i_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 echo_q_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME echo_q_axis, FREQ_HZ 184320000" *)
    input  wire [63:0]  echo_q_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 echo_q_axis TVALID" *)
    input  wire         echo_q_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 ref_i_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ref_i_axis, FREQ_HZ 184320000" *)
    input  wire [63:0]  ref_i_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 ref_i_axis TVALID" *)
    input  wire         ref_i_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 ref_q_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME ref_q_axis, FREQ_HZ 184320000" *)
    input  wire [63:0]  ref_q_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 ref_q_axis TVALID" *)
    input  wire         ref_q_axis_tvalid,

    output wire         radar_enabled,
    output reg          tx_active,
    output reg          capture_active,
    output reg          background_valid
);

    localparam integer PULSE_BEATS   = PULSE_SAMPLES / 4;
    localparam integer CAPTURE_BEATS = CAPTURE_SAMPLES / 4;
    localparam integer CORR_SAMPLES  = CAPTURE_SAMPLES - MAX_LAG;
    localparam integer PRF_CYCLES    = CLK_FREQ_HZ / PRF_HZ;

    localparam [31:0] CMD_STOP       = 32'h524e4700;
    localparam [31:0] CMD_START      = 32'h524e4701;
    localparam [31:0] CMD_BGCAL      = 32'h42474341;
    localparam [31:0] RESULT_MAGIC   = 32'h524e4731;

    localparam [3:0] PROC_IDLE        = 4'd0;
    localparam [3:0] PROC_CAPTURE     = 4'd1;
    localparam [3:0] PROC_CORR_READ   = 4'd2;
    localparam [3:0] PROC_CORR_MULT   = 4'd3;
    localparam [3:0] PROC_CORR_ACCUM  = 4'd4;
    localparam [3:0] PROC_CORR_DIFF   = 4'd5;
    localparam [3:0] PROC_CORR_MAG    = 4'd6;
    localparam [3:0] PROC_CORR_UPDATE = 4'd7;
    localparam [3:0] PROC_FINALIZE    = 4'd8;
    localparam [3:0] PROC_OUTPUT      = 4'd9;
    localparam [3:0] PROC_CFAR_PREFIX = 4'd10;
    localparam [3:0] PROC_CFAR_SCAN   = 4'd11;

    // One-dimensional CA-CFAR parameters.  Scores are retained at their
    // native 49-bit precision; the absolute floor is expressed in the same
    // Q16-scaled units used by the legacy software threshold.
    localparam integer CFAR_TRAIN_CELLS = 2;
    localparam integer CFAR_GUARD_CELLS = 1;
    localparam integer CFAR_SCALE       = 2;
    localparam integer MAX_TARGETS      = 4;
    localparam [48:0] CFAR_ABS_THRESHOLD = (1000 << 16);

    // Synchronous block ROM.  The build scripts make ROM_FILE visible to the
    // synthesis working directory; simulation overrides it with a local path.
    (* rom_style = "block" *) reg [127:0] waveform_rom [0:PULSE_BEATS-1];
    reg [127:0] waveform_data;
    initial begin
        $readmemh(ROM_FILE, waveform_rom);
    end

    // Each memory word stores four I samples and four Q samples:
    // bits [63:0] are I0..I3 and bits [127:64] are Q0..Q3.
    (* ram_style = "block" *) reg [127:0] reference_mem [0:CAPTURE_BEATS-1];
    (* ram_style = "block" *) reg [127:0] echo_mem      [0:CAPTURE_BEATS-1];
    (* ram_style = "block" *) reg [95:0]  background_mem [0:MAX_LAG-1];

    reg [127:0] reference_read_data;
    reg [127:0] echo_read_data;
    reg [95:0]  background_read_data;

    reg                enabled;
    reg                calibrate_request;
    reg                scan_calibrate;
    reg [31:0]         prf_counter;
    reg [15:0]         tx_beat_index;
    reg [15:0]         capture_beat_index;
    (* fsm_encoding = "sequential" *) reg [3:0] proc_state;
    reg [15:0]         lag_index;
    reg [15:0]         sample_index;
    reg [1:0]          ref_lane_index;
    reg [1:0]          echo_lane_index;
    // Single-lane II=1 correlation pipeline bookkeeping.  sample_index is
    // the address issue counter; the two valid bits account for the
    // synchronous BRAM read and registered multiplier stages.
    reg                corr_read_valid;
    reg                corr_product_valid;
    reg [15:0]         corr_accum_count;
    reg signed [47:0]  corr_acc_re;
    reg signed [47:0]  corr_acc_im;
    reg signed [31:0]  mult_ei_ri_pipe;
    reg signed [31:0]  mult_eq_rq_pipe;
    reg signed [31:0]  mult_eq_ri_pipe;
    reg signed [31:0]  mult_ei_rq_pipe;
    reg signed [47:0]  corr_sum_re_pipe;
    reg signed [47:0]  corr_sum_im_pipe;
    reg signed [47:0]  corr_diff_re_pipe;
    reg signed [47:0]  corr_diff_im_pipe;
    reg [48:0]         magnitude_pipe;
    reg [48:0]         max_score;
    reg [15:0]         max_lag_index;
    reg [48:0]         max_left_score;
    reg [48:0]         max_right_score;
    reg [48:0]         previous_score;
    reg                max_waiting_right;
    reg [15:0]         final_peak_lag;
    reg [48:0]         final_peak_score;
    reg [48:0]         final_left_score;
    reg [48:0]         final_right_score;
    reg [15:0]         result_sequence;
    reg [3:0]          output_word_index;

    // Full range profile and CA-CFAR working storage.  Prefix sums keep the
    // per-cell CFAR operation bounded to a few adds/subtracts rather than a
    // variable-size training-window loop.
    reg [48:0]         lag_scores [0:MAX_LAG-1];
    reg [63:0]         cfar_prefix [0:MAX_LAG];
    reg [15:0]         cfar_prefix_index;
    reg [63:0]         cfar_running_sum;
    reg [15:0]         cfar_index;
    reg [2:0]          target_count;
    reg [15:0]         target_lag [0:MAX_TARGETS-1];
    reg [48:0]         target_score [0:MAX_TARGETS-1];
    reg [15:0]         cfar_suppress_until;

    reg [15:0] cfar_left_start, cfar_left_end;
    reg [15:0] cfar_right_start, cfar_right_end;
    reg [63:0] cfar_train_sum;
    reg [7:0]  cfar_train_count;
    reg [63:0] cfar_threshold;
    reg        cfar_candidate;
    integer cfar_tmp_count;

    wire adc_valid = echo_i_axis_tvalid && echo_q_axis_tvalid &&
                     ref_i_axis_tvalid  && ref_q_axis_tvalid;
    wire ctrl_fire = s_axis_ctrl_tvalid && s_axis_ctrl_tready;
    wire tx_start = enabled && !tx_active && (prf_counter == 0);
    wire capture_write_enable = capture_active && adc_valid;
    wire [15:0] echo_sample_address = sample_index + lag_index;
    wire [15:0] reference_read_address = sample_index >> 2;
    wire [15:0] echo_read_address = echo_sample_address >> 2;

    assign s_axis_ctrl_tready = 1'b1;
    assign radar_enabled = enabled;
    assign m0_axis_tdata = tx_active ? waveform_data : 128'd0;
    assign m1_axis_tdata = m0_axis_tdata;
    assign m0_axis_tvalid = 1'b1;
    assign m1_axis_tvalid = 1'b1;

    function signed [15:0] select_lane;
        input [63:0] word;
        input [1:0] lane;
        begin
            case (lane)
                2'd0: select_lane = word[15:0];
                2'd1: select_lane = word[31:16];
                2'd2: select_lane = word[47:32];
                default: select_lane = word[63:48];
            endcase
        end
    endfunction

    function [47:0] abs48;
        input signed [47:0] value;
        begin
            abs48 = value[47] ? (~value + 1'b1) : value;
        end
    endfunction

    function [31:0] scaled_score;
        input [48:0] value;
        begin
            scaled_score = value[47:16];
        end
    endfunction

    wire signed [15:0] corr_ref_i =
        select_lane(reference_read_data[63:0], ref_lane_index);
    wire signed [15:0] corr_ref_q =
        select_lane(reference_read_data[127:64], ref_lane_index);
    wire signed [15:0] corr_echo_i =
        select_lane(echo_read_data[63:0], echo_lane_index);
    wire signed [15:0] corr_echo_q =
        select_lane(echo_read_data[127:64], echo_lane_index);

    wire signed [31:0] mult_ei_ri = corr_echo_i * corr_ref_i;
    wire signed [31:0] mult_eq_rq = corr_echo_q * corr_ref_q;
    wire signed [31:0] mult_eq_ri = corr_echo_q * corr_ref_i;
    wire signed [31:0] mult_ei_rq = corr_echo_i * corr_ref_q;
    wire signed [32:0] product_re_pipe =
        $signed(mult_ei_ri_pipe) + $signed(mult_eq_rq_pipe);
    wire signed [32:0] product_im_pipe =
        $signed(mult_eq_ri_pipe) - $signed(mult_ei_rq_pipe);
    wire signed [47:0] product_re_extended =
        {{15{product_re_pipe[32]}}, product_re_pipe};
    wire signed [47:0] product_im_extended =
        {{15{product_im_pipe[32]}}, product_im_pipe};
    wire signed [47:0] corr_acc_next_re =
        corr_acc_re + product_re_extended;
    wire signed [47:0] corr_acc_next_im =
        corr_acc_im + product_im_extended;
    wire signed [47:0] background_read_re = background_read_data[95:48];
    wire signed [47:0] background_read_im = background_read_data[47:0];
    wire background_write_enable =
        (proc_state == PROC_CORR_DIFF) && scan_calibrate;

    // CA-CFAR window arithmetic.  The edge cells naturally have fewer
    // training cells; the measured count is used for the average.
    always @* begin
        cfar_left_start  = 16'd0;
        cfar_left_end    = 16'd0;
        cfar_right_start = 16'd0;
        cfar_right_end   = 16'd0;
        cfar_train_sum   = 64'd0;
        cfar_tmp_count   = 0;
        cfar_train_count = 8'd0;
        cfar_threshold   = 64'hffffffffffffffff;
        cfar_candidate   = 1'b0;

        // Do not index unpacked arrays until the registered scan index is
        // known to be in range.  Besides being safer RTL, this avoids a
        // Vivado 2020.2 xsim failure when an X-valued time-zero index is used.
        if ((proc_state == PROC_CFAR_SCAN) && (cfar_index < MAX_LAG)) begin
            cfar_left_start  = (cfar_index > (CFAR_GUARD_CELLS + CFAR_TRAIN_CELLS)) ?
                                cfar_index - CFAR_GUARD_CELLS - CFAR_TRAIN_CELLS : 0;
            cfar_left_end    = (cfar_index > CFAR_GUARD_CELLS) ?
                                cfar_index - CFAR_GUARD_CELLS : 0;
            cfar_right_start = cfar_index + CFAR_GUARD_CELLS + 1;
            cfar_right_end   = cfar_index + CFAR_GUARD_CELLS + CFAR_TRAIN_CELLS + 1;
            if (cfar_right_start > MAX_LAG)
                cfar_right_start = MAX_LAG;
            if (cfar_right_end > MAX_LAG)
                cfar_right_end = MAX_LAG;
            cfar_train_sum =
                (cfar_prefix[cfar_left_end] - cfar_prefix[cfar_left_start]) +
                (cfar_prefix[cfar_right_end] - cfar_prefix[cfar_right_start]);
            cfar_tmp_count = (cfar_left_end - cfar_left_start) +
                             (cfar_right_end - cfar_right_start);
            cfar_train_count = cfar_tmp_count;

            // With two training cells on each side, the normal interior case
            // has four training cells.  Avoid a general-purpose divider.
            case (cfar_train_count)
                8'd1: cfar_threshold = cfar_train_sum * 2;
                8'd2: cfar_threshold = cfar_train_sum;
                8'd3: cfar_threshold = (cfar_train_sum * 2) / 3;
                8'd4: cfar_threshold = cfar_train_sum >> 1;
                default: cfar_threshold = 64'hffffffffffffffff;
            endcase

            cfar_candidate = (cfar_tmp_count != 0) &&
                ({15'd0, lag_scores[cfar_index]} >= CFAR_ABS_THRESHOLD) &&
                ({15'd0, lag_scores[cfar_index]} >= cfar_threshold);
            if (cfar_index != 0)
                cfar_candidate = cfar_candidate &&
                    (lag_scores[cfar_index] > lag_scores[cfar_index-1]);
            if (cfar_index != MAX_LAG-1)
                cfar_candidate = cfar_candidate &&
                    (lag_scores[cfar_index] >= lag_scores[cfar_index+1]);
        end
    end

    // The ROM output is prepared one beat ahead so the AXI output presents
    // each waveform word exactly once despite the synchronous ROM latency.
    always @(posedge clk) begin
        if (tx_start) begin
            waveform_data <= waveform_rom[0];
        end else if (tx_active && tx_beat_index < PULSE_BEATS - 1) begin
            waveform_data <= waveform_rom[tx_beat_index + 1'b1];
        end
    end

    // Simple-dual-port BRAM templates.  Deliberately no reset is applied to
    // the memories or their read ports; validity is controlled by the FSM.
    always @(posedge clk) begin
        if (capture_write_enable) begin
            reference_mem[capture_beat_index] <= {
                ref_q_axis_tdata, ref_i_axis_tdata
            };
            echo_mem[capture_beat_index] <= {
                echo_q_axis_tdata, echo_i_axis_tdata
            };
        end

        reference_read_data <= reference_mem[reference_read_address];
        echo_read_data <= echo_mem[echo_read_address];

        if (background_write_enable) begin
            background_mem[lag_index] <= {
                corr_sum_re_pipe, corr_sum_im_pipe
            };
        end
        background_read_data <= background_mem[lag_index];
    end

    // Control, counters and AXI result generation.  This block never writes
    // a memory, so its asynchronous reset cannot prevent BRAM inference.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            enabled              <= 1'b0;
            calibrate_request    <= 1'b0;
            scan_calibrate       <= 1'b0;
            background_valid     <= 1'b0;
            prf_counter          <= 32'd0;
            tx_active            <= 1'b0;
            tx_beat_index        <= 16'd0;
            capture_active       <= 1'b0;
            capture_beat_index   <= 16'd0;
            proc_state           <= PROC_IDLE;
            lag_index            <= 16'd0;
            sample_index         <= 16'd0;
            ref_lane_index       <= 2'd0;
            echo_lane_index      <= 2'd0;
            corr_read_valid      <= 1'b0;
            corr_product_valid   <= 1'b0;
            corr_accum_count     <= 16'd0;
            corr_acc_re          <= 48'sd0;
            corr_acc_im          <= 48'sd0;
            mult_ei_ri_pipe      <= 32'sd0;
            mult_eq_rq_pipe      <= 32'sd0;
            mult_eq_ri_pipe      <= 32'sd0;
            mult_ei_rq_pipe      <= 32'sd0;
            corr_sum_re_pipe     <= 48'sd0;
            corr_sum_im_pipe     <= 48'sd0;
            corr_diff_re_pipe    <= 48'sd0;
            corr_diff_im_pipe    <= 48'sd0;
            magnitude_pipe       <= 49'd0;
            max_score            <= 49'd0;
            max_lag_index        <= 16'd0;
            max_left_score       <= 49'd0;
            max_right_score      <= 49'd0;
            previous_score       <= 49'd0;
            max_waiting_right    <= 1'b0;
            final_peak_lag       <= 16'd0;
            final_peak_score     <= 49'd0;
            final_left_score     <= 49'd0;
            final_right_score    <= 49'd0;
            result_sequence      <= 16'd0;
            output_word_index    <= 3'd0;
            cfar_prefix_index    <= 16'd0;
            cfar_running_sum     <= 64'd0;
            cfar_index           <= 16'd0;
            target_count         <= 3'd0;
            cfar_suppress_until  <= 16'd0;
            m_axis_result_tdata  <= 32'd0;
            m_axis_result_tvalid <= 1'b0;
            m_axis_result_tlast  <= 1'b0;
        end else begin
            if (ctrl_fire) begin
                case (s_axis_ctrl_tdata)
                    CMD_START: enabled <= 1'b1;
                    CMD_STOP:  enabled <= 1'b0;
                    CMD_BGCAL: calibrate_request <= 1'b1;
                    default: begin end
                endcase
            end

            if (enabled) begin
                if (prf_counter == PRF_CYCLES - 1)
                    prf_counter <= 32'd0;
                else
                    prf_counter <= prf_counter + 1'b1;
            end else begin
                prf_counter <= 32'd0;
            end

            if (!enabled) begin
                tx_active <= 1'b0;
            end else if (tx_start) begin
                tx_active     <= 1'b1;
                tx_beat_index <= 16'd0;
                if (proc_state == PROC_IDLE) begin
                    capture_active     <= 1'b1;
                    capture_beat_index <= 16'd0;
                    scan_calibrate     <= calibrate_request;
                    calibrate_request  <= 1'b0;
                    proc_state         <= PROC_CAPTURE;
                end
            end else if (tx_active) begin
                if (tx_beat_index == PULSE_BEATS - 1) begin
                    tx_active     <= 1'b0;
                    tx_beat_index <= 16'd0;
                end else begin
                    tx_beat_index <= tx_beat_index + 1'b1;
                end
            end

            if (capture_write_enable) begin
                if (capture_beat_index == CAPTURE_BEATS - 1) begin
                    capture_active     <= 1'b0;
                    capture_beat_index <= 16'd0;
                    lag_index          <= 16'd0;
                    sample_index       <= 16'd0;
                    corr_acc_re        <= 48'sd0;
                    corr_acc_im        <= 48'sd0;
                    corr_read_valid    <= 1'b0;
                    corr_product_valid <= 1'b0;
                    corr_accum_count   <= 16'd0;
                    max_score          <= 49'd0;
                    max_lag_index      <= 16'd0;
                    max_left_score     <= 49'd0;
                    max_right_score    <= 49'd0;
                    previous_score     <= 49'd0;
                    max_waiting_right  <= 1'b0;
                    proc_state         <= PROC_CORR_READ;
                end else begin
                    capture_beat_index <= capture_beat_index + 1'b1;
                end
            end

            // Single-lane II=1 correlation pipeline.  A new sample address is
            // issued on every clock while the current lag is being processed.
            // BRAM read data, complex products and the accumulator are each
            // registered, so the first result appears after the two-cycle
            // pipeline fill and one result is retired on every subsequent
            // clock.  The final two clocks drain the BRAM/product stages.
            if (proc_state == PROC_CORR_READ) begin
                // Issue the next reference/echo address and retain its lane
                // selectors for the synchronous BRAM output one cycle later.
                if (sample_index < CORR_SAMPLES) begin
                    ref_lane_index  <= sample_index[1:0];
                    echo_lane_index <= echo_sample_address[1:0];
                    sample_index    <= sample_index + 1'b1;
                    corr_read_valid <= 1'b1;
                end else begin
                    corr_read_valid <= 1'b0;
                end

                // Register the product made from the preceding BRAM read.
                // corr_product_valid is the corresponding valid delay.
                mult_ei_ri_pipe    <= mult_ei_ri;
                mult_eq_rq_pipe    <= mult_eq_rq;
                mult_eq_ri_pipe    <= mult_eq_ri;
                mult_ei_rq_pipe    <= mult_ei_rq;
                corr_product_valid <= corr_read_valid;

                // Retire one product per cycle once the pipeline is filled.
                // The final product is handled identically, then the state
                // advances to the existing background/difference stages.
                if (corr_product_valid) begin
                    if (corr_accum_count == CORR_SAMPLES - 1) begin
                        corr_sum_re_pipe <= corr_acc_next_re;
                        corr_sum_im_pipe <= corr_acc_next_im;
                        corr_acc_re      <= 48'sd0;
                        corr_acc_im      <= 48'sd0;
                        corr_accum_count <= 16'd0;
                        corr_read_valid  <= 1'b0;
                        corr_product_valid <= 1'b0;
                        sample_index     <= 16'd0;
                        proc_state       <= PROC_CORR_DIFF;
                    end else begin
                        corr_acc_re      <= corr_acc_next_re;
                        corr_acc_im      <= corr_acc_next_im;
                        corr_accum_count <= corr_accum_count + 1'b1;
                    end
                end
            end

            // DIFF: background RAM data and the completed correlation meet only
            // in this registered subtract stage.  Calibration writes the raw
            // completed correlation through the independent BRAM process.
            if (proc_state == PROC_CORR_DIFF) begin
                corr_diff_re_pipe <= background_valid ?
                    (corr_sum_re_pipe - background_read_re) :
                    corr_sum_re_pipe;
                corr_diff_im_pipe <= background_valid ?
                    (corr_sum_im_pipe - background_read_im) :
                    corr_sum_im_pipe;
                proc_state <= PROC_CORR_MAG;
            end

            // MAG: register abs(real) + abs(imaginary).  UPDATE therefore has
            // no combinational dependency on either capture BRAM read port.
            if (proc_state == PROC_CORR_MAG) begin
                magnitude_pipe <=
                    {1'b0, abs48(corr_diff_re_pipe)} +
                    {1'b0, abs48(corr_diff_im_pipe)};
                proc_state <= PROC_CORR_UPDATE;
            end

            // UPDATE: peak and neighbour tracking is driven only by the
            // registered magnitude, cutting the reference_mem-to-max_score CE
            // path at every arithmetic boundary.
            if (proc_state == PROC_CORR_UPDATE) begin
                if (scan_calibrate) begin
                    if (lag_index == MAX_LAG - 1) begin
                        background_valid  <= 1'b1;
                        final_peak_lag    <= 16'd0;
                        final_peak_score  <= 49'd0;
                        final_left_score  <= 49'd0;
                        final_right_score <= 49'd0;
                        target_count      <= 3'd0;
                        proc_state        <= PROC_FINALIZE;
                    end else begin
                        lag_index  <= lag_index + 1'b1;
                        proc_state <= PROC_CORR_READ;
                    end
                end else begin
                    previous_score <= magnitude_pipe;
                    // Retain every lag score for the post-correlation
                    // CFAR/multi-target pass, while preserving legacy peak
                    // tracking for interpolation compatibility.
                    lag_scores[lag_index] <= magnitude_pipe;
                    if (magnitude_pipe > max_score) begin
                        max_score         <= magnitude_pipe;
                        max_lag_index     <= lag_index;
                        max_left_score    <= (lag_index == 0) ?
                            49'd0 : previous_score;
                        max_right_score   <= 49'd0;
                        max_waiting_right <= (lag_index != MAX_LAG - 1);
                    end else if (max_waiting_right) begin
                        max_right_score   <= magnitude_pipe;
                        max_waiting_right <= 1'b0;
                    end

                    if (lag_index == MAX_LAG - 1) begin
                        if (magnitude_pipe > max_score) begin
                            final_peak_lag    <= lag_index;
                            final_peak_score  <= magnitude_pipe;
                            final_left_score  <= (lag_index == 0) ?
                                49'd0 : previous_score;
                            final_right_score <= 49'd0;
                        end else begin
                            final_peak_lag   <= max_lag_index;
                            final_peak_score <= max_score;
                            final_left_score <= max_left_score;
                            final_right_score <= max_waiting_right ?
                                magnitude_pipe : max_right_score;
                        end
                        cfar_prefix_index   <= 16'd0;
                        cfar_running_sum    <= 64'd0;
                        cfar_index          <= 16'd0;
                        target_count        <= 3'd0;
                        cfar_suppress_until <= 16'd0;
                        proc_state          <= PROC_CFAR_PREFIX;
                    end else begin
                        lag_index  <= lag_index + 1'b1;
                        proc_state <= PROC_CORR_READ;
                    end
                end
            end

            // Build an inclusive prefix sum of the complete range profile.
            // This state is deliberately sequential to keep CFAR resources
            // bounded and to make the profile observable in simulation.
            if (proc_state == PROC_CFAR_PREFIX) begin
                if (cfar_prefix_index < MAX_LAG) begin
                    cfar_prefix[cfar_prefix_index] <= cfar_running_sum;
                    cfar_running_sum <= cfar_running_sum +
                                        {{15{1'b0}}, lag_scores[cfar_prefix_index]};
                    cfar_prefix_index <= cfar_prefix_index + 1'b1;
                end else begin
                    cfar_prefix[MAX_LAG] <= cfar_running_sum;
                    cfar_index <= 16'd0;
                    proc_state <= PROC_CFAR_SCAN;
                end
            end

            // One lag per clock CA-CFAR scan.  A local-maximum test suppresses
            // broad sidelobes, while cfar_suppress_until implements a simple
            // non-maximum suppression guard around each accepted target.
            if (proc_state == PROC_CFAR_SCAN) begin
                if (cfar_candidate && (cfar_index >= cfar_suppress_until) &&
                    (target_count < MAX_TARGETS)) begin
                    target_lag[target_count]   <= cfar_index;
                    target_score[target_count] <= lag_scores[cfar_index];
                    target_count                <= target_count + 1'b1;
                    cfar_suppress_until        <= cfar_index + CFAR_GUARD_CELLS + 1;
                end
                if (cfar_index == MAX_LAG - 1) begin
                    proc_state <= PROC_FINALIZE;
                end else begin
                    cfar_index <= cfar_index + 1'b1;
                end
            end

            if (proc_state == PROC_FINALIZE) begin
                // Reconstruct neighbours for the first reported target so
                // legacy software RCAL/sub-sample interpolation remains
                // meaningful.  Additional targets carry lag and score only.
                if (target_count != 0) begin
                    final_peak_lag   <= target_lag[0];
                    final_peak_score <= target_score[0];
                    final_left_score <= (target_lag[0] == 0) ? 49'd0 :
                                        lag_scores[target_lag[0]-1'b1];
                    final_right_score <= (target_lag[0] == MAX_LAG-1) ? 49'd0 :
                                         lag_scores[target_lag[0]+1'b1];
                end
                output_word_index    <= 4'd0;
                m_axis_result_tvalid <= 1'b0;
                m_axis_result_tlast  <= 1'b0;
                proc_state           <= PROC_OUTPUT;
            end

            if (proc_state == PROC_OUTPUT) begin
                if (!m_axis_result_tvalid || m_axis_result_tready) begin
                    m_axis_result_tvalid <= 1'b1;
                    m_axis_result_tlast  <= 1'b0;
                    case (output_word_index)
                        4'd0: m_axis_result_tdata <= RESULT_MAGIC;
                        // v1 header: [31:24] version, [23:16] target count,
                        // [15:0] sequence number.
                        4'd1: m_axis_result_tdata <= {
                            8'h01, 8'd0 + target_count, result_sequence
                        };
                        4'd2: m_axis_result_tdata <= {
                            29'd0, background_valid, scan_calibrate, enabled
                        };
                        4'd3: m_axis_result_tdata <= (target_count > 0) ?
                            {16'd0, target_lag[0]} : 32'd0;
                        4'd4: m_axis_result_tdata <= (target_count > 0) ?
                            scaled_score(target_score[0]) : 32'd0;
                        4'd5: m_axis_result_tdata <= (target_count > 1) ?
                            {16'd0, target_lag[1]} : 32'd0;
                        4'd6: m_axis_result_tdata <= (target_count > 1) ?
                            scaled_score(target_score[1]) : 32'd0;
                        4'd7: m_axis_result_tdata <= (target_count > 2) ?
                            {16'd0, target_lag[2]} : 32'd0;
                        4'd8: m_axis_result_tdata <= (target_count > 2) ?
                            scaled_score(target_score[2]) : 32'd0;
                        4'd9: m_axis_result_tdata <= (target_count > 3) ?
                            {16'd0, target_lag[3]} : 32'd0;
                        4'd10: m_axis_result_tdata <= (target_count > 3) ?
                            scaled_score(target_score[3]) : 32'd0;
                        4'd11: m_axis_result_tdata <= scaled_score(final_left_score);
                        4'd12: m_axis_result_tdata <= scaled_score(final_right_score);
                        default: begin
                            m_axis_result_tdata <= {
                                29'd0, background_valid,
                                scan_calibrate, enabled
                            };
                            m_axis_result_tlast <= 1'b1;
                        end
                    endcase

                    if (output_word_index == 4'd13) begin
                        output_word_index <= 4'd0;
                        result_sequence   <= result_sequence + 1'b1;
                        proc_state        <= PROC_IDLE;
                        scan_calibrate    <= 1'b0;
                    end else begin
                        output_word_index <= output_word_index + 1'b1;
                    end
                end
            end else if (m_axis_result_tvalid && m_axis_result_tready) begin
                m_axis_result_tvalid <= 1'b0;
                m_axis_result_tlast  <= 1'b0;
            end
        end
    end

endmodule
