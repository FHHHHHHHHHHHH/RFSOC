`timescale 1ns/1ps

module tb_quant_stream_mux_protocol;
    reg clk = 0;
    reg rstn = 0;
    always #2 clk = ~clk;

    reg [255:0] snapshot_data = 0;
    reg snapshot_valid = 0;
    wire snapshot_ready;
    reg snapshot_last = 1;

    reg [63:0] signal_data = 64'h0123_4567_89ab_cdef;
    reg signal_valid = 0;
    wire signal_ready;
    reg signal_last = 1;

    wire [255:0] out_data;
    wire out_valid;
    reg out_ready = 1;
    wire out_last;

    reg [255:0] expected_data [0:7];
    integer accepted_count = 0;
    integer emitted_count = 0;

    quant_stream_mux dut (
        .aclk(clk),
        .aresetn(rstn),
        .s_snapshot_tdata(snapshot_data),
        .s_snapshot_tvalid(snapshot_valid),
        .s_snapshot_tready(snapshot_ready),
        .s_snapshot_tlast(snapshot_last),
        .s_signal_tdata(signal_data),
        .s_signal_tvalid(signal_valid),
        .s_signal_tready(signal_ready),
        .s_signal_tlast(signal_last),
        .m_axis_tdata(out_data),
        .m_axis_tvalid(out_valid),
        .m_axis_tready(out_ready),
        .m_axis_tlast(out_last)
    );

    always @(posedge clk) begin
        if (rstn) begin
            if (signal_valid && signal_ready) begin
                expected_data[accepted_count] = {{192{1'b0}}, signal_data};
                accepted_count = accepted_count + 1;
            end
            if (snapshot_valid && snapshot_ready) begin
                expected_data[accepted_count] = snapshot_data;
                accepted_count = accepted_count + 1;
            end
            if (out_valid && out_ready) begin
                if (emitted_count >= accepted_count)
                    $fatal(1, "AXIS violation: output emitted before an input handshake");
                if (out_data !== expected_data[emitted_count])
                    $fatal(1, "AXIS violation: output data mismatch at beat %0d", emitted_count);
                emitted_count = emitted_count + 1;
            end
        end
    end

    initial begin
        repeat (3) @(posedge clk);
        @(negedge clk);
        rstn = 1;

        // 单个 signal 只能产生一个输出 beat。
        signal_data = 64'h0123_4567_89ab_cdef;
        signal_valid = 1;
        do @(posedge clk); while (!signal_ready);
        @(negedge clk);
        signal_valid = 0;
        while (emitted_count < 1) @(posedge clk);

        // 下游反压时允许装入空输出寄存器，但输出必须保持稳定且不能重复接收。
        @(negedge clk);
        out_ready = 0;
        snapshot_data = 256'h1234_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_abcd;
        snapshot_valid = 1;
        do @(posedge clk); while (!snapshot_ready);
        @(negedge clk);
        snapshot_valid = 0;
        repeat (2) @(posedge clk);
        if (!out_valid || out_data !== snapshot_data || emitted_count != 1)
            $fatal(1, "AXIS violation: output changed or advanced during backpressure");
        @(negedge clk);
        out_ready = 1;
        while (emitted_count < 2) @(posedge clk);

        // 两路同时有效时 signal 优先，snapshot 保持到下一次握手。
        @(negedge clk);
        signal_data = 64'hfeed_face_0000_0001;
        snapshot_data = 256'h5678_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_0000_dcba;
        signal_valid = 1;
        snapshot_valid = 1;
        #1;
        if (!signal_ready || snapshot_ready)
            $fatal(1, "AXIS violation: signal priority ready selection is incorrect");
        @(posedge clk);
        @(negedge clk);
        signal_valid = 0;
        do @(posedge clk); while (!snapshot_ready);
        @(negedge clk);
        snapshot_valid = 0;
        while (emitted_count < 4) @(posedge clk);

        repeat (2) @(posedge clk);
        if (accepted_count != 4 || emitted_count != 4)
            $fatal(1, "AXIS violation: accepted=%0d emitted=%0d", accepted_count, emitted_count);
        $display("PASS AXIS mux accepted=%0d emitted=%0d", accepted_count, emitted_count);
        $finish;
    end

    initial begin
        #1000;
        $fatal(1, "timeout");
    end
endmodule
