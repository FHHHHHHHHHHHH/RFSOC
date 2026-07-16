`timescale 1ns / 1ps

module tb_dbpsk_loopback;
    localparam integer CLK_FREQ_HZ = 184_320_000;
    localparam integer BAUD_RATE   = 10_000_000;
    localparam real CLK_PERIOD_NS  = 1.0e9 / CLK_FREQ_HZ;
    localparam real TWO_PI         = 6.2831853071795864769;
    localparam integer PAYLOAD_LEN = 5;

    reg clk = 1'b0;
    reg rst_n = 1'b0;
    always #(CLK_PERIOD_NS/2.0) clk = ~clk;

    reg [31:0] tx_s_tdata = 32'd0;
    reg        tx_s_tvalid = 1'b0;
    wire       tx_s_tready;
    reg        tx_s_tlast = 1'b0;
    wire [127:0] tx_m0_tdata;
    wire [127:0] tx_m1_tdata;
    wire tx_m0_tvalid;
    wire tx_m1_tvalid;
    wire tx_active;
    wire tx_frame_start;

    reg [31:0] adc_i_tdata = 32'd0;
    reg [31:0] adc_q_tdata = 32'd0;
    reg adc_i_tvalid = 1'b1;
    reg adc_q_tvalid = 1'b1;

    wire [31:0] rx_m_tdata;
    wire rx_m_tvalid;
    reg  rx_m_tready = 1'b1;
    wire rx_m_tlast;
    wire [31:0] good_frame_count;
    wire [31:0] bad_frame_count;

    byte frame [0:255];
    integer frame_length;
    integer output_word_count = 0;
    integer sample_number = 0;
    integer adc_i_value;
    integer adc_q_value;
    real carrier_angle;
    real phase_sign;

    dual_dac_dbpsk_tx #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) tx_dut (
        .clk(clk),
        .rst_n(rst_n),
        .s_axis_tdata(tx_s_tdata),
        .s_axis_tvalid(tx_s_tvalid),
        .s_axis_tready(tx_s_tready),
        .s_axis_tlast(tx_s_tlast),
        .m0_axis_tdata(tx_m0_tdata),
        .m0_axis_tvalid(tx_m0_tvalid),
        .m1_axis_tdata(tx_m1_tdata),
        .m1_axis_tvalid(tx_m1_tvalid),
        .tx_active(tx_active),
        .frame_start(tx_frame_start)
    );

    dbpsk_adc_rx_v10 #(
        .CLK_FREQ_HZ(CLK_FREQ_HZ),
        .BAUD_RATE(BAUD_RATE)
    ) rx_dut (
        .clk(clk),
        .rst_n(rst_n),
        .adc_i_axis_tdata(adc_i_tdata),
        .adc_i_axis_tvalid(adc_i_tvalid),
        .adc_q_axis_tdata(adc_q_tdata),
        .adc_q_axis_tvalid(adc_q_tvalid),
        .m_axis_tdata(rx_m_tdata),
        .m_axis_tvalid(rx_m_tvalid),
        .m_axis_tready(rx_m_tready),
        .m_axis_tlast(rx_m_tlast),
        .good_frame_count(good_frame_count),
        .bad_frame_count(bad_frame_count)
    );

    function automatic [15:0] crc16_byte;
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

    task automatic send_frame;
        integer index;
        begin
            for (index = 0; index < frame_length; index = index + 1) begin
                tx_s_tdata  <= {24'd0, frame[index]};
                tx_s_tlast  <= (index == frame_length - 1);
                tx_s_tvalid <= 1'b1;
                do @(posedge clk); while (!tx_s_tready);
                tx_s_tvalid <= 1'b0;
                tx_s_tlast  <= 1'b0;
            end
        end
    endtask

    // Ideal DAC/NCO/cable/ADC model. The receiver uses sample 0 only, so both
    // packed samples are set to the same value for this functional test.
    always @(posedge clk) begin
        if (!rst_n) begin
            sample_number <= 0;
            adc_i_tdata <= 32'd0;
            adc_q_tdata <= 32'd0;
        end else begin
            phase_sign = $signed(tx_m0_tdata[15:0]) < 0 ? -1.0 : 1.0;
            carrier_angle = -TWO_PI * 10.0e6 * sample_number / CLK_FREQ_HZ;
            adc_i_value = $rtoi(phase_sign * 12000.0 * $cos(carrier_angle));
            adc_q_value = $rtoi(phase_sign * 12000.0 * $sin(carrier_angle));
            adc_i_tdata <= {adc_i_value[15:0], adc_i_value[15:0]};
            adc_q_tdata <= {adc_q_value[15:0], adc_q_value[15:0]};
            sample_number <= sample_number + 1;
        end
    end

    always @(posedge clk) begin
        if (rx_m_tvalid && rx_m_tready) begin
            case (output_word_count)
                0: if (rx_m_tdata !== {8'hD5, 8'h01, 16'd5})
                       $fatal(1, "Bad RX header: %08x", rx_m_tdata);
                1: if (rx_m_tdata[7:0] !== "H") $fatal(1, "Bad payload byte 0");
                2: if (rx_m_tdata[7:0] !== "E") $fatal(1, "Bad payload byte 1");
                3: if (rx_m_tdata[7:0] !== "L") $fatal(1, "Bad payload byte 2");
                4: if (rx_m_tdata[7:0] !== "L") $fatal(1, "Bad payload byte 3");
                5: if (rx_m_tdata[7:0] !== "O") $fatal(1, "Bad payload byte 4");
            endcase
            output_word_count <= output_word_count + 1;
            if (rx_m_tlast) begin
                if (output_word_count != 5)
                    $fatal(1, "Unexpected output packet length");
                $display("PASS: DBPSK loopback decoded HELLO, good=%0d bad=%0d",
                         good_frame_count, bad_frame_count);
                #100;
                $finish;
            end
        end
    end

    initial begin
        reg [15:0] crc;
        integer idx;
        repeat (20) @(posedge clk);
        rst_n <= 1'b1;

        frame[0] = 8'hFF;
        frame[1] = 8'hFF;
        frame[2] = 8'hFF;
        frame[3] = 8'hFF;
        frame[4] = 8'hD3;
        frame[5] = 8'h91;
        frame[6] = 8'hC5;
        frame[7] = 8'hA7;
        frame[8] = 8'h00;
        frame[9] = PAYLOAD_LEN;
        frame[10] = "H";
        frame[11] = "E";
        frame[12] = "L";
        frame[13] = "L";
        frame[14] = "O";

        crc = 16'hFFFF;
        for (idx = 8; idx <= 14; idx = idx + 1)
            crc = crc16_byte(crc, frame[idx]);
        frame[15] = crc[15:8];
        frame[16] = crc[7:0];
        frame_length = 17;

        // Give the receiver time to estimate the continuous idle carrier.
        repeat (1800) @(posedge clk);
        send_frame();

        repeat (20000) @(posedge clk);
        $fatal(1, "Timeout: receiver did not produce a frame; good=%0d bad=%0d state=%0d",
               good_frame_count, bad_frame_count, rx_dut.state);
    end

endmodule
