`timescale 1ns / 1ps

// Non-coherent DBPSK receiver for the ADC10 IQ stream.
//
// ADC I and Q each contain two consecutive signed 16-bit samples per beat.
// This receiver uses sample 0, giving a processing rate of 184.32 MSPS. The
// RFDC output is expected at approximately -10 MHz. A local complex NCO moves
// it to baseband. The continuous idle carrier establishes a phase reference;
// the first phase reversal starts the symbol clock. Decoded frames use:
//
//   4 x FF preamble | D3 91 C5 A7 sync | length[15:0] | payload | CRC16
//
// CRC16-CCITT is calculated over the two length bytes and the payload. On a
// completed frame the output packet contains a status header followed by one
// payload byte per 32-bit AXIS word:
//
//   header = D5 | status | payload_length
//
module dbpsk_adc_rx_v10 #(
    parameter integer CLK_FREQ_HZ = 184_320_000,
    parameter integer BAUD_RATE   = 10_000_000,
    parameter [31:0]  NCO_PHASE_INC = 32'hF21C71C7,
    parameter [31:0]  SYNC_WORD   = 32'hD391C5A7,
    parameter integer MAX_PAYLOAD = 256
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF adc_i_axis:adc_q_axis:m_axis, ASSOCIATED_RESET rst_n, FREQ_HZ 184320000" *)
    input  wire        clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rst_n RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire        rst_n,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 adc_i_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME adc_i_axis, FREQ_HZ 184320000" *)
    input  wire [31:0] adc_i_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 adc_i_axis TVALID" *)
    input  wire        adc_i_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 adc_q_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME adc_q_axis, FREQ_HZ 184320000" *)
    input  wire [31:0] adc_q_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 adc_q_axis TVALID" *)
    input  wire        adc_q_axis_tvalid,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TDATA" *)
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME m_axis, FREQ_HZ 184320000" *)
    output reg  [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TVALID" *)
    output reg         m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis TLAST" *)
    output reg         m_axis_tlast,

    output reg  [31:0] good_frame_count,
    output reg  [31:0] bad_frame_count
);

    localparam [2:0] ST_ACQUIRE = 3'd0;
    localparam [2:0] ST_SYNC    = 3'd1;
    localparam [2:0] ST_LENGTH  = 3'd2;
    localparam [2:0] ST_PAYLOAD = 3'd3;
    localparam [2:0] ST_CRC_HI  = 3'd4;
    localparam [2:0] ST_CRC_LO  = 3'd5;
    localparam [2:0] ST_OUTPUT  = 3'd6;

    localparam integer HALF_CLK_PHASE = CLK_FREQ_HZ / 2;

    reg [2:0] state;
    reg [31:0] nco_phase;
    reg [31:0] baud_phase;

    reg signed [15:0] adc_i_s1;
    reg signed [15:0] adc_q_s1;
    reg signed [15:0] cos_s1;
    reg signed [15:0] sin_s1;
    reg                valid_s1;

    reg signed [31:0] prod_ic_s2;
    reg signed [31:0] prod_qs_s2;
    reg signed [31:0] prod_qc_s2;
    reg signed [31:0] prod_is_s2;
    reg                valid_s2;

    reg signed [17:0] mix_i_s3;
    reg signed [17:0] mix_q_s3;
    reg                valid_s3;

    reg signed [23:0] ref_i;
    reg signed [23:0] ref_q;
    reg [10:0]         ref_count;
    reg                ref_valid;

    reg signed [41:0] proj_i_s4;
    reg signed [41:0] proj_q_s4;
    reg                valid_s4;
    reg signed [42:0] projection_s5;
    reg                valid_s5;

    reg stable_sign;
    reg candidate_sign;
    reg [2:0] candidate_count;
    reg transition_pulse;

    reg previous_symbol_sign;
    reg [31:0] sync_shift;
    reg [7:0]  byte_shift;
    reg [2:0]  bit_count;
    reg         length_byte_sel;
    reg [7:0]   length_hi;
    reg [15:0]  payload_length;
    reg [15:0]  payload_index;
    reg [15:0]  crc_value;
    reg [7:0]   received_crc_hi;
    reg [7:0]   payload_mem [0:MAX_PAYLOAD-1];

    reg         output_ok;
    reg [15:0]  output_length;
    reg [16:0]  output_index;

    wire adc_valid = adc_i_axis_tvalid && adc_q_axis_tvalid;
    wire signed [15:0] adc_i_sample0 = adc_i_axis_tdata[15:0];
    wire signed [15:0] adc_q_sample0 = adc_q_axis_tdata[15:0];
    wire raw_sign = projection_s5[42];
    wire center_tick = (baud_phase < HALF_CLK_PHASE) &&
                       ((baud_phase + BAUD_RATE) >= HALF_CLK_PHASE);
    wire symbol_wrap = baud_phase >= (CLK_FREQ_HZ - BAUD_RATE);
    wire decoded_bit = stable_sign ^ previous_symbol_sign;
    wire [7:0] assembled_byte = {byte_shift[6:0], decoded_bit};
    wire [31:0] sync_shift_next = {sync_shift[30:0], decoded_bit};

    function signed [15:0] quarter_sine;
        input [6:0] address;
        begin
            case (address)
                7'd0: quarter_sine = 16'sd0;
                7'd1: quarter_sine = 16'sd804;
                7'd2: quarter_sine = 16'sd1608;
                7'd3: quarter_sine = 16'sd2410;
                7'd4: quarter_sine = 16'sd3212;
                7'd5: quarter_sine = 16'sd4011;
                7'd6: quarter_sine = 16'sd4808;
                7'd7: quarter_sine = 16'sd5602;
                7'd8: quarter_sine = 16'sd6393;
                7'd9: quarter_sine = 16'sd7179;
                7'd10: quarter_sine = 16'sd7962;
                7'd11: quarter_sine = 16'sd8739;
                7'd12: quarter_sine = 16'sd9512;
                7'd13: quarter_sine = 16'sd10278;
                7'd14: quarter_sine = 16'sd11039;
                7'd15: quarter_sine = 16'sd11793;
                7'd16: quarter_sine = 16'sd12539;
                7'd17: quarter_sine = 16'sd13279;
                7'd18: quarter_sine = 16'sd14010;
                7'd19: quarter_sine = 16'sd14732;
                7'd20: quarter_sine = 16'sd15446;
                7'd21: quarter_sine = 16'sd16151;
                7'd22: quarter_sine = 16'sd16846;
                7'd23: quarter_sine = 16'sd17530;
                7'd24: quarter_sine = 16'sd18204;
                7'd25: quarter_sine = 16'sd18868;
                7'd26: quarter_sine = 16'sd19519;
                7'd27: quarter_sine = 16'sd20159;
                7'd28: quarter_sine = 16'sd20787;
                7'd29: quarter_sine = 16'sd21403;
                7'd30: quarter_sine = 16'sd22005;
                7'd31: quarter_sine = 16'sd22594;
                7'd32: quarter_sine = 16'sd23170;
                7'd33: quarter_sine = 16'sd23731;
                7'd34: quarter_sine = 16'sd24279;
                7'd35: quarter_sine = 16'sd24811;
                7'd36: quarter_sine = 16'sd25329;
                7'd37: quarter_sine = 16'sd25832;
                7'd38: quarter_sine = 16'sd26319;
                7'd39: quarter_sine = 16'sd26790;
                7'd40: quarter_sine = 16'sd27245;
                7'd41: quarter_sine = 16'sd27683;
                7'd42: quarter_sine = 16'sd28105;
                7'd43: quarter_sine = 16'sd28510;
                7'd44: quarter_sine = 16'sd28898;
                7'd45: quarter_sine = 16'sd29268;
                7'd46: quarter_sine = 16'sd29621;
                7'd47: quarter_sine = 16'sd29956;
                7'd48: quarter_sine = 16'sd30273;
                7'd49: quarter_sine = 16'sd30571;
                7'd50: quarter_sine = 16'sd30852;
                7'd51: quarter_sine = 16'sd31113;
                7'd52: quarter_sine = 16'sd31356;
                7'd53: quarter_sine = 16'sd31580;
                7'd54: quarter_sine = 16'sd31785;
                7'd55: quarter_sine = 16'sd31971;
                7'd56: quarter_sine = 16'sd32137;
                7'd57: quarter_sine = 16'sd32285;
                7'd58: quarter_sine = 16'sd32412;
                7'd59: quarter_sine = 16'sd32521;
                7'd60: quarter_sine = 16'sd32609;
                7'd61: quarter_sine = 16'sd32678;
                7'd62: quarter_sine = 16'sd32728;
                7'd63: quarter_sine = 16'sd32757;
                default: quarter_sine = 16'sd32767;
            endcase
        end
    endfunction

    function signed [15:0] sine_lut;
        input [7:0] phase;
        reg [6:0] mirror_address;
        begin
            mirror_address = 7'd64 - {1'b0, phase[5:0]};
            case (phase[7:6])
                2'b00: sine_lut = quarter_sine({1'b0, phase[5:0]});
                2'b01: sine_lut = quarter_sine(mirror_address);
                2'b10: sine_lut = -quarter_sine({1'b0, phase[5:0]});
                default: sine_lut = -quarter_sine(mirror_address);
            endcase
        end
    endfunction

    function [15:0] crc16_byte;
        input [15:0] crc_in;
        input [7:0] data_in;
        integer k;
        reg [15:0] crc;
        begin
            crc = crc_in ^ {data_in, 8'h00};
            for (k = 0; k < 8; k = k + 1) begin
                if (crc[15])
                    crc = (crc << 1) ^ 16'h1021;
                else
                    crc = crc << 1;
            end
            crc16_byte = crc;
        end
    endfunction

    // Complex NCO and mixer pipeline.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nco_phase  <= 32'd0;
            adc_i_s1   <= 16'sd0;
            adc_q_s1   <= 16'sd0;
            cos_s1     <= 16'sd0;
            sin_s1     <= 16'sd0;
            valid_s1   <= 1'b0;
            prod_ic_s2 <= 32'sd0;
            prod_qs_s2 <= 32'sd0;
            prod_qc_s2 <= 32'sd0;
            prod_is_s2 <= 32'sd0;
            valid_s2   <= 1'b0;
            mix_i_s3   <= 18'sd0;
            mix_q_s3   <= 18'sd0;
            valid_s3   <= 1'b0;
        end else begin
            valid_s1 <= adc_valid;
            valid_s2 <= valid_s1;
            valid_s3 <= valid_s2;
            if (adc_valid) begin
                adc_i_s1  <= adc_i_sample0;
                adc_q_s1  <= adc_q_sample0;
                cos_s1    <= sine_lut(nco_phase[31:24] + 8'd64);
                sin_s1    <= sine_lut(nco_phase[31:24]);
                nco_phase <= nco_phase + NCO_PHASE_INC;
            end
            if (valid_s1) begin
                prod_ic_s2 <= adc_i_s1 * cos_s1;
                prod_qs_s2 <= adc_q_s1 * sin_s1;
                prod_qc_s2 <= adc_q_s1 * cos_s1;
                prod_is_s2 <= adc_i_s1 * sin_s1;
            end
            if (valid_s2) begin
                mix_i_s3 <= ($signed(prod_ic_s2) + $signed(prod_qs_s2)) >>> 15;
                mix_q_s3 <= ($signed(prod_qc_s2) - $signed(prod_is_s2)) >>> 15;
            end
        end
    end

    // Idle reference, phase projection, and debounced phase-state detector.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ref_i           <= 24'sd0;
            ref_q           <= 24'sd0;
            ref_count       <= 11'd0;
            ref_valid       <= 1'b0;
            proj_i_s4       <= 42'sd0;
            proj_q_s4       <= 42'sd0;
            valid_s4        <= 1'b0;
            projection_s5   <= 43'sd0;
            valid_s5        <= 1'b0;
            stable_sign     <= 1'b0;
            candidate_sign  <= 1'b0;
            candidate_count <= 3'd0;
            transition_pulse <= 1'b0;
        end else begin
            transition_pulse <= 1'b0;
            valid_s4 <= valid_s3;
            valid_s5 <= valid_s4;

            if (valid_s3) begin
                if (state == ST_ACQUIRE) begin
                    ref_i <= ref_i + (($signed({{6{mix_i_s3[17]}}, mix_i_s3}) - ref_i) >>> 6);
                    ref_q <= ref_q + (($signed({{6{mix_q_s3[17]}}, mix_q_s3}) - ref_q) >>> 6);
                    if (!ref_valid) begin
                        if (ref_count == 11'd1023)
                            ref_valid <= 1'b1;
                        else
                            ref_count <= ref_count + 1'b1;
                    end
                end
                proj_i_s4 <= mix_i_s3 * ref_i;
                proj_q_s4 <= mix_q_s3 * ref_q;
            end
            if (valid_s4)
                projection_s5 <= $signed(proj_i_s4) + $signed(proj_q_s4);

            if (valid_s5 && ref_valid) begin
                if (raw_sign == stable_sign) begin
                    candidate_sign  <= raw_sign;
                    candidate_count <= 3'd0;
                end else if (raw_sign != candidate_sign) begin
                    candidate_sign  <= raw_sign;
                    candidate_count <= 3'd1;
                end else if (candidate_count == 3'd3) begin
                    stable_sign      <= candidate_sign;
                    candidate_count  <= 3'd0;
                    transition_pulse <= 1'b1;
                end else begin
                    candidate_count <= candidate_count + 1'b1;
                end
            end

            // Rebuild a clean idle reference after every completed frame.
            if ((state == ST_OUTPUT) && m_axis_tvalid && m_axis_tready && m_axis_tlast) begin
                ref_i            <= 24'sd0;
                ref_q            <= 24'sd0;
                ref_count        <= 11'd0;
                ref_valid        <= 1'b0;
                stable_sign      <= 1'b0;
                candidate_count  <= 3'd0;
            end
        end
    end

    // Symbol timing, frame parser, CRC checker, and output packetizer.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state                <= ST_ACQUIRE;
            baud_phase           <= 32'd0;
            previous_symbol_sign <= 1'b0;
            sync_shift           <= 32'd0;
            byte_shift           <= 8'd0;
            bit_count            <= 3'd0;
            length_byte_sel      <= 1'b0;
            length_hi            <= 8'd0;
            payload_length       <= 16'd0;
            payload_index        <= 16'd0;
            crc_value            <= 16'hFFFF;
            received_crc_hi      <= 8'd0;
            output_ok            <= 1'b0;
            output_length        <= 16'd0;
            output_index         <= 17'd0;
            m_axis_tdata         <= 32'd0;
            m_axis_tvalid        <= 1'b0;
            m_axis_tlast         <= 1'b0;
            good_frame_count     <= 32'd0;
            bad_frame_count      <= 32'd0;
        end else begin
            if (state == ST_ACQUIRE) begin
                baud_phase <= 32'd0;
                if (transition_pulse && ref_valid) begin
                    state                <= ST_SYNC;
                    previous_symbol_sign <= ~stable_sign;
                    sync_shift           <= 32'd0;
                    baud_phase           <= 32'd0;
                end
            end else if (state != ST_OUTPUT && valid_s5) begin
                if (symbol_wrap)
                    baud_phase <= baud_phase + BAUD_RATE - CLK_FREQ_HZ;
                else
                    baud_phase <= baud_phase + BAUD_RATE;

                if (center_tick) begin
                    previous_symbol_sign <= stable_sign;
                    case (state)
                        ST_SYNC: begin
                            sync_shift <= sync_shift_next;
                            if (sync_shift_next == SYNC_WORD) begin
                                state           <= ST_LENGTH;
                                bit_count       <= 3'd0;
                                length_byte_sel <= 1'b0;
                                byte_shift      <= 8'd0;
                                crc_value       <= 16'hFFFF;
                            end
                        end

                        ST_LENGTH: begin
                            byte_shift <= assembled_byte;
                            if (bit_count == 3'd7) begin
                                bit_count <= 3'd0;
                                crc_value <= crc16_byte(crc_value, assembled_byte);
                                if (!length_byte_sel) begin
                                    length_hi       <= assembled_byte;
                                    length_byte_sel <= 1'b1;
                                end else begin
                                    payload_length  <= {length_hi, assembled_byte};
                                    payload_index   <= 16'd0;
                                    length_byte_sel <= 1'b0;
                                    if ({length_hi, assembled_byte} > MAX_PAYLOAD) begin
                                        state           <= ST_ACQUIRE;
                                        bad_frame_count <= bad_frame_count + 1'b1;
                                    end else if ({length_hi, assembled_byte} == 0) begin
                                        state <= ST_CRC_HI;
                                    end else begin
                                        state <= ST_PAYLOAD;
                                    end
                                end
                            end else begin
                                bit_count <= bit_count + 1'b1;
                            end
                        end

                        ST_PAYLOAD: begin
                            byte_shift <= assembled_byte;
                            if (bit_count == 3'd7) begin
                                bit_count <= 3'd0;
                                payload_mem[payload_index] <= assembled_byte;
                                crc_value <= crc16_byte(crc_value, assembled_byte);
                                if (payload_index + 1'b1 >= payload_length) begin
                                    state <= ST_CRC_HI;
                                end else begin
                                    payload_index <= payload_index + 1'b1;
                                end
                            end else begin
                                bit_count <= bit_count + 1'b1;
                            end
                        end

                        ST_CRC_HI: begin
                            byte_shift <= assembled_byte;
                            if (bit_count == 3'd7) begin
                                bit_count       <= 3'd0;
                                received_crc_hi <= assembled_byte;
                                state           <= ST_CRC_LO;
                            end else begin
                                bit_count <= bit_count + 1'b1;
                            end
                        end

                        ST_CRC_LO: begin
                            byte_shift <= assembled_byte;
                            if (bit_count == 3'd7) begin
                                bit_count     <= 3'd0;
                                output_ok     <= ({received_crc_hi, assembled_byte} == crc_value);
                                output_length <= payload_length;
                                output_index  <= 17'd0;
                                state         <= ST_OUTPUT;
                                m_axis_tdata  <= {
                                    8'hD5,
                                    (({received_crc_hi, assembled_byte} == crc_value) ? 8'h01 : 8'h00),
                                    payload_length
                                };
                                m_axis_tvalid <= 1'b1;
                                m_axis_tlast  <= ({received_crc_hi, assembled_byte} != crc_value) ||
                                                 (payload_length == 0);
                                if ({received_crc_hi, assembled_byte} == crc_value)
                                    good_frame_count <= good_frame_count + 1'b1;
                                else
                                    bad_frame_count <= bad_frame_count + 1'b1;
                            end else begin
                                bit_count <= bit_count + 1'b1;
                            end
                        end

                        default: state <= ST_ACQUIRE;
                    endcase
                end
            end

            if (state == ST_OUTPUT && m_axis_tvalid && m_axis_tready) begin
                if (m_axis_tlast) begin
                    m_axis_tvalid        <= 1'b0;
                    m_axis_tlast         <= 1'b0;
                    state                <= ST_ACQUIRE;
                    baud_phase           <= 32'd0;
                    sync_shift           <= 32'd0;
                    previous_symbol_sign <= 1'b0;
                end else begin
                    output_index <= output_index + 1'b1;
                    m_axis_tdata <= {24'd0, payload_mem[output_index]};
                    if (output_index + 1'b1 >= output_length)
                        m_axis_tlast <= 1'b1;
                end
            end
        end
    end

endmodule
