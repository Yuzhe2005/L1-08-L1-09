`default_nettype none


import base_plan_l1_09_pkg::*;

module l1_09_allpass_coeff_bank #(
    parameter int SECTION_COUNT = SECTION_COUNT_DEFAULT,
    parameter int COEFF_WIDTH   = COEFF_WIDTH_DEFAULT
) (
    input  logic                               clk,
    input  logic                               reset_n,
    output logic                               coeffs_ready,
    output logic signed [COEFF_WIDTH-1:0]      a1 [SECTION_COUNT],
    output logic signed [COEFF_WIDTH-1:0]      a2 [SECTION_COUNT]
);
    logic signed [COEFF_WIDTH-1:0] coeff_a1 [SECTION_COUNT];
    logic signed [COEFF_WIDTH-1:0] coeff_a2 [SECTION_COUNT];

    assign a1           = coeff_a1;
    assign a2           = coeff_a2;
    assign coeffs_ready = reset_n;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            `include `BASE_PLAN_L1_09_COEFF_RESET_SVH
        end
    end
endmodule

module iir_biquad_df1_stage #(
    parameter int DATA_W          = DATA_WIDTH_DEFAULT,
    parameter int COEFF_W         = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACC_W           = ACCUM_WIDTH_DEFAULT
) (
    input  logic                             clk,
    input  logic                             reset_n,
    input  logic                             stage_en,
    input  logic signed [DATA_W-1:0]         x_in,
    input  logic signed [COEFF_W-1:0]        a1,
    input  logic signed [COEFF_W-1:0]        a2,
    output logic signed [DATA_W-1:0]         y_out
);
    localparam int MULT_W = DATA_W + COEFF_W;

    logic signed [DATA_W-1:0]      x1;
    logic signed [DATA_W-1:0]      x2;
    logic signed [DATA_W-1:0]      y1;
    logic signed [DATA_W-1:0]      y2;
    logic signed [MULT_W-1:0]      prod_x0_a2;
    logic signed [MULT_W-1:0]      prod_x1_a1;
    logic signed [MULT_W-1:0]      prod_x2_unity;
    logic signed [MULT_W-1:0]      prod_a1;
    logic signed [MULT_W-1:0]      prod_a2;
    logic signed [ACC_W-1:0]       acc;
    logic signed [DATA_W-1:0]      y_next;

    function automatic logic signed [DATA_W-1:0] round_sat_qx(
        input logic signed [ACC_W-1:0] value
    );
        logic signed [ACC_W-1:0] rounded;
        logic signed [ACC_W-1:0] shifted;
        logic signed [ACC_W-1:0] max_out;
        logic signed [ACC_W-1:0] min_out;
        begin
            max_out = {{(ACC_W-DATA_W){1'b0}}, 1'b0, {DATA_W-1{1'b1}}};
            min_out = {{(ACC_W-DATA_W){1'b1}}, 1'b1, {DATA_W-1{1'b0}}};
            rounded = (COEFF_FRAC_BITS == 0) ? value : (value + (1 <<< (COEFF_FRAC_BITS - 1)));
            shifted = rounded >>> COEFF_FRAC_BITS;
            if (shifted > max_out) begin
                round_sat_qx = {1'b0, {DATA_W-1{1'b1}}};
            end else if (shifted < min_out) begin
                round_sat_qx = {1'b1, {DATA_W-1{1'b0}}};
            end else begin
                round_sat_qx = shifted[DATA_W-1:0];
            end
        end
    endfunction

    function automatic logic signed [ACC_W-1:0] sign_extend_prod(
        input logic signed [MULT_W-1:0] value
    );
        return {{(ACC_W - MULT_W){value[MULT_W-1]}}, value};
    endfunction

    always_comb begin
        prod_x0_a2    = x_in * a2;
        prod_x1_a1    = x1   * a1;
        prod_x2_unity = {{COEFF_W{x2[DATA_W-1]}}, x2} <<< COEFF_FRAC_BITS;
        prod_a1       = y1   * a1;
        prod_a2       = y2   * a2;
        acc = sign_extend_prod(prod_x0_a2)
            + sign_extend_prod(prod_x1_a1)
            + sign_extend_prod(prod_x2_unity)
            - sign_extend_prod(prod_a1)
            - sign_extend_prod(prod_a2);
        y_next = round_sat_qx(acc);
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            x1    <= '0;
            x2    <= '0;
            y1    <= '0;
            y2    <= '0;
            y_out <= '0;
        end else if (stage_en) begin
            y_out <= y_next;
            x2    <= x1;
            x1    <= x_in;
            y2    <= y1;
            y1    <= y_next;
        end
    end
endmodule

module iir_sos_cascade #(
    parameter int SECTION_COUNT   = SECTION_COUNT_DEFAULT,
    parameter int DATA_W          = DATA_WIDTH_DEFAULT,
    parameter int COEFF_W         = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACC_W           = ACCUM_WIDTH_DEFAULT
) (
    input  logic                             clk,
    input  logic                             reset_n,
    input  logic                             stage_en,
    input  logic signed [DATA_W-1:0]         x_in,
    input  logic signed [COEFF_W-1:0]         a1 [SECTION_COUNT],
    input  logic signed [COEFF_W-1:0]         a2 [SECTION_COUNT],
    output logic signed [DATA_W-1:0]         y_out
);
    logic signed [DATA_W-1:0] stage_in  [SECTION_COUNT];
    logic signed [DATA_W-1:0] stage_out [SECTION_COUNT];

    assign stage_in[0] = x_in;

    generate
        for (genvar sec = 1; sec < SECTION_COUNT; sec++) begin : g_stage_in
            assign stage_in[sec] = stage_out[sec - 1];
        end

        for (genvar sec = 0; sec < SECTION_COUNT; sec++) begin : g_sec
            iir_biquad_df1_stage #(
                .DATA_W(DATA_W),
                .COEFF_W(COEFF_W),
                .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
                .ACC_W(ACC_W)
            ) u_biquad (
                .clk(clk),
                .reset_n(reset_n),
                .stage_en(stage_en),
                .x_in(stage_in[sec]),
                .a1(a1[sec]),
                .a2(a2[sec]),
                .y_out(stage_out[sec])
            );
        end
    endgenerate

    assign y_out = stage_out[SECTION_COUNT-1];
endmodule

module L1_09 #(
    parameter int SECTION_COUNT   = SECTION_COUNT_DEFAULT,
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH     = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_EXTRA_BITS = 3,
    parameter int ACCUM_WIDTH     = DATA_WIDTH + COEFF_WIDTH + ACCUM_EXTRA_BITS,
    parameter int IIR_LATENCY     = IIR_LATENCY_DEFAULT
) (
    input  logic                             clk,
    input  logic                             reset_n,

    input  logic signed [DATA_WIDTH-1:0]     i_in,
    input  logic signed [DATA_WIDTH-1:0]     q_in,
    input  logic                             in_valid,

    output logic signed [DATA_WIDTH-1:0]     o_i,
    output logic signed [DATA_WIDTH-1:0]     o_q,
    output logic                             o_valid,

    input  logic                             bypass
);
    logic signed [COEFF_WIDTH-1:0] coeff_a1 [SECTION_COUNT];
    logic signed [COEFF_WIDTH-1:0] coeff_a2 [SECTION_COUNT];

    logic signed [DATA_WIDTH-1:0]   filt_i;
    logic signed [DATA_WIDTH-1:0]   filt_q;

    logic                           coeffs_ready;
    logic                           run_valid;
    logic                           iir_valid_in;
    logic                           iir_out_valid;
    logic [IIR_LATENCY-1:0]         iir_valid_pipe;

    assign run_valid     = in_valid && coeffs_ready;
    assign iir_valid_in  = run_valid && !bypass;
    assign iir_out_valid = iir_valid_pipe[IIR_LATENCY-1];

    l1_09_allpass_coeff_bank #(
        .SECTION_COUNT(SECTION_COUNT),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) u_coeff_bank (
        .clk(clk),
        .reset_n(reset_n),
        .coeffs_ready(coeffs_ready),
        .a1(coeff_a1),
        .a2(coeff_a2)
    );

    iir_sos_cascade #(
        .SECTION_COUNT(SECTION_COUNT),
        .DATA_W(DATA_WIDTH),
        .COEFF_W(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .ACC_W(ACCUM_WIDTH)
    ) u_iir_i (
        .clk(clk),
        .reset_n(reset_n),
        .stage_en(run_valid),
        .x_in(i_in),
        .a1(coeff_a1),
        .a2(coeff_a2),
        .y_out(filt_i)
    );

    iir_sos_cascade #(
        .SECTION_COUNT(SECTION_COUNT),
        .DATA_W(DATA_WIDTH),
        .COEFF_W(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .ACC_W(ACCUM_WIDTH)
    ) u_iir_q (
        .clk(clk),
        .reset_n(reset_n),
        .stage_en(run_valid),
        .x_in(q_in),
        .a1(coeff_a1),
        .a2(coeff_a2),
        .y_out(filt_q)
    );

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            iir_valid_pipe <= '0;
            o_i            <= '0;
            o_q            <= '0;
            o_valid        <= 1'b0;
        end else begin
            o_valid <= 1'b0;

            if (run_valid) begin
                iir_valid_pipe <= {iir_valid_pipe[IIR_LATENCY-2:0], iir_valid_in};
            end

            if (in_valid && coeffs_ready && bypass) begin
                o_i     <= i_in;
                o_q     <= q_in;
                o_valid <= 1'b1;
            end else if (run_valid && iir_out_valid) begin
                o_i     <= filt_i;
                o_q     <= filt_q;
                o_valid <= 1'b1;
            end
        end
    end
endmodule
