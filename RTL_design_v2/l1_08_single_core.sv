`default_nettype none

import base_plan_l1_08_v2_pkg::*;

module l1_08_v2_coeff_bank #(
    parameter int TAP_NUM     = TAP_NUM_DEFAULT,
    parameter int COEFF_WIDTH = COEFF_WIDTH_DEFAULT
) (
    input  logic                          reset_n,
    output logic                          coeffs_ready,
    output logic signed [COEFF_WIDTH-1:0] coeff [TAP_NUM]
);
    // Constant ROM keeps every coefficient available in parallel to the MACs.
    `include `BASE_PLAN_L1_08_V2_COEFF_RESET_SVH

    assign coeffs_ready = reset_n;

    generate
        for (genvar coeff_idx = 0; coeff_idx < TAP_NUM; coeff_idx++) begin : gen_coeff_rom
            assign coeff[coeff_idx] = L1_08_FIR_COEFF_ROM[coeff_idx];
        end
    endgenerate
endmodule

module l1_08_v2_fir_mac #(
    parameter int TAP_NUM = TAP_NUM_DEFAULT,
    parameter int DATA_W  = DATA_WIDTH_DEFAULT,
    parameter int COEFF_W = COEFF_WIDTH_DEFAULT,
    parameter int ACC_W   = ACCUM_WIDTH_DEFAULT
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic                         enable,
    input  logic signed [DATA_W-1:0]     sample_window [TAP_NUM],
    input  logic signed [COEFF_W-1:0]    coeff [TAP_NUM],
    output logic signed [ACC_W-1:0]      mac_out
);
    localparam int PROD_W = DATA_W + COEFF_W;
    localparam int S1_NUM = (TAP_NUM + 1) / 2;
    localparam int S2_NUM = (S1_NUM + 1) / 2;
    localparam int S3_NUM = (S2_NUM + 1) / 2;
    localparam int S4_NUM = (S3_NUM + 1) / 2;
    localparam int S5_NUM = (S4_NUM + 1) / 2;
    localparam int S6_NUM = (S5_NUM + 1) / 2;

    logic signed [PROD_W-1:0] prod [TAP_NUM];
    logic signed [ACC_W-1:0]  s1 [S1_NUM];
    logic signed [ACC_W-1:0]  s2 [S2_NUM];
    logic signed [ACC_W-1:0]  s3 [S3_NUM];
    logic signed [ACC_W-1:0]  s4 [S4_NUM];
    logic signed [ACC_W-1:0]  s5 [S5_NUM];
    logic signed [ACC_W-1:0]  s6 [S6_NUM];

    genvar tap_idx;
    generate
        for (tap_idx = 0; tap_idx < TAP_NUM; tap_idx++) begin : gen_products
            assign prod[tap_idx] = sample_window[tap_idx] * coeff[tap_idx];
        end
    endgenerate

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            for (int idx = 0; idx < S1_NUM; idx++) begin
                s1[idx] <= '0;
            end
            for (int idx = 0; idx < S2_NUM; idx++) begin
                s2[idx] <= '0;
            end
            for (int idx = 0; idx < S3_NUM; idx++) begin
                s3[idx] <= '0;
            end
            for (int idx = 0; idx < S4_NUM; idx++) begin
                s4[idx] <= '0;
            end
            for (int idx = 0; idx < S5_NUM; idx++) begin
                s5[idx] <= '0;
            end
            for (int idx = 0; idx < S6_NUM; idx++) begin
                s6[idx] <= '0;
            end
            mac_out <= '0;
        end else if (enable) begin
            for (int idx = 0; idx < S1_NUM; idx++) begin
                if ((2 * idx + 1) < TAP_NUM) begin
                    s1[idx] <= $signed(prod[2 * idx]) + $signed(prod[2 * idx + 1]);
                end else begin
                    s1[idx] <= $signed(prod[2 * idx]);
                end
            end

            for (int idx = 0; idx < S2_NUM; idx++) begin
                if ((2 * idx + 1) < S1_NUM) begin
                    s2[idx] <= s1[2 * idx] + s1[2 * idx + 1];
                end else begin
                    s2[idx] <= s1[2 * idx];
                end
            end

            for (int idx = 0; idx < S3_NUM; idx++) begin
                if ((2 * idx + 1) < S2_NUM) begin
                    s3[idx] <= s2[2 * idx] + s2[2 * idx + 1];
                end else begin
                    s3[idx] <= s2[2 * idx];
                end
            end

            for (int idx = 0; idx < S4_NUM; idx++) begin
                if ((2 * idx + 1) < S3_NUM) begin
                    s4[idx] <= s3[2 * idx] + s3[2 * idx + 1];
                end else begin
                    s4[idx] <= s3[2 * idx];
                end
            end

            for (int idx = 0; idx < S5_NUM; idx++) begin
                if ((2 * idx + 1) < S4_NUM) begin
                    s5[idx] <= s4[2 * idx] + s4[2 * idx + 1];
                end else begin
                    s5[idx] <= s4[2 * idx];
                end
            end

            for (int idx = 0; idx < S6_NUM; idx++) begin
                if ((2 * idx + 1) < S5_NUM) begin
                    s6[idx] <= s5[2 * idx] + s5[2 * idx + 1];
                end else begin
                    s6[idx] <= s5[2 * idx];
                end
            end

            if (S6_NUM > 1) begin
                mac_out <= s6[0] + s6[1];
            end else begin
                mac_out <= s6[0];
            end
        end
    end
endmodule

module l1_08_v2_core_single #(
    parameter int TAP_NUM          = TAP_NUM_DEFAULT,
    parameter int DATA_WIDTH       = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH      = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS  = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH      = ACCUM_WIDTH_DEFAULT,
    parameter int MAC_LATENCY      = MAC_LATENCY_DEFAULT
) (
    input  logic                             clk,
    input  logic                             reset_n,
    input  logic                             clear,
    input  logic                             enable,
    input  logic signed [DATA_WIDTH-1:0]     x_i,
    input  logic signed [DATA_WIDTH-1:0]     x_q,
    input  logic                             in_valid,
    output logic signed [DATA_WIDTH-1:0]     y_i,
    output logic signed [DATA_WIDTH-1:0]     y_q,
    output logic                             y_valid,
    output logic                             coeffs_ready
);
    localparam int OUTPUT_LATENCY    = MAC_LATENCY;

    logic signed [DATA_WIDTH-1:0]  i_window [TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  q_window [TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  mac_i_window [TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  mac_q_window [TAP_NUM];
    logic signed [COEFF_WIDTH-1:0] coeff [TAP_NUM];
    logic signed [ACCUM_WIDTH-1:0] mac_i;
    logic signed [ACCUM_WIDTH-1:0] mac_q;
    logic [OUTPUT_LATENCY-1:0]     mac_valid_pipe;
    logic                          run_valid;
    logic                          mac_out_valid;

    assign run_valid     = enable && in_valid && coeffs_ready;
    assign mac_out_valid = mac_valid_pipe[OUTPUT_LATENCY-1];

    always_comb begin
        mac_i_window[0] = x_i;
        mac_q_window[0] = x_q;
        for (int idx = 1; idx < TAP_NUM; idx++) begin
            mac_i_window[idx] = i_window[idx - 1];
            mac_q_window[idx] = q_window[idx - 1];
        end
    end

    l1_08_v2_coeff_bank #(
        .TAP_NUM(TAP_NUM),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) u_coeff_bank (
        .reset_n(reset_n),
        .coeffs_ready(coeffs_ready),
        .coeff(coeff)
    );

    l1_08_v2_fir_mac #(
        .TAP_NUM(TAP_NUM),
        .DATA_W(DATA_WIDTH),
        .COEFF_W(COEFF_WIDTH),
        .ACC_W(ACCUM_WIDTH)
    ) u_mac_i (
        .clk(clk),
        .reset_n(reset_n),
        .enable(enable),
        .sample_window(mac_i_window),
        .coeff(coeff),
        .mac_out(mac_i)
    );

    l1_08_v2_fir_mac #(
        .TAP_NUM(TAP_NUM),
        .DATA_W(DATA_WIDTH),
        .COEFF_W(COEFF_WIDTH),
        .ACC_W(ACCUM_WIDTH)
    ) u_mac_q (
        .clk(clk),
        .reset_n(reset_n),
        .enable(enable),
        .sample_window(mac_q_window),
        .coeff(coeff),
        .mac_out(mac_q)
    );

    function automatic logic signed [DATA_WIDTH-1:0] round_sat_q15(
        input logic signed [ACCUM_WIDTH-1:0] value
    );
        localparam int SHIFT = COEFF_FRAC_BITS;
        logic signed [ACCUM_WIDTH:0] rounded;
        logic signed [ACCUM_WIDTH:0] shifted;
        logic signed [ACCUM_WIDTH:0] max_out;
        logic signed [ACCUM_WIDTH:0] min_out;
        begin
            if (SHIFT > 0) begin
                rounded = {value[ACCUM_WIDTH-1], value}
                        + {{(ACCUM_WIDTH-SHIFT+1){1'b0}}, 1'b1, {(SHIFT-1){1'b0}}};
                shifted = rounded >>> SHIFT;
            end else begin
                shifted = {value[ACCUM_WIDTH-1], value};
            end

            max_out = $signed({1'b0, {(DATA_WIDTH-1){1'b1}}});
            min_out = $signed({1'b1, {(DATA_WIDTH-1){1'b0}}});

            if (shifted > max_out) begin
                round_sat_q15 = max_out[DATA_WIDTH-1:0];
            end else if (shifted < min_out) begin
                round_sat_q15 = min_out[DATA_WIDTH-1:0];
            end else begin
                round_sat_q15 = shifted[DATA_WIDTH-1:0];
            end
        end
    endfunction

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            for (int idx = 0; idx < TAP_NUM; idx++) begin
                i_window[idx] <= '0;
                q_window[idx] <= '0;
            end
            mac_valid_pipe <= '0;
            y_i            <= '0;
            y_q            <= '0;
            y_valid        <= 1'b0;
        end else if (enable) begin
            mac_valid_pipe <= {mac_valid_pipe[OUTPUT_LATENCY-2:0], run_valid};

            if (run_valid) begin
                for (int idx = TAP_NUM - 1; idx > 0; idx--) begin
                    i_window[idx] <= i_window[idx - 1];
                    q_window[idx] <= q_window[idx - 1];
                end
                i_window[0] <= x_i;
                q_window[0] <= x_q;
            end

            if (mac_out_valid) begin
                y_i     <= round_sat_q15(mac_i);
                y_q     <= round_sat_q15(mac_q);
                y_valid <= 1'b1;
            end else begin
                y_i     <= '0;
                y_q     <= '0;
                y_valid <= 1'b0;
            end
        end
    end
endmodule

`default_nettype wire
