`default_nettype none

import base_plan_l1_09_v2_pkg::*;

module l1_09_v2_coeff_bank #(
    parameter int SECTION_COUNT = SECTION_COUNT_DEFAULT,
    parameter int COEFF_WIDTH   = COEFF_WIDTH_DEFAULT
) (
    input  logic                          reset_n,
    output logic                          coeffs_ready,
    output logic signed [COEFF_WIDTH-1:0] a1 [SECTION_COUNT],
    output logic signed [COEFF_WIDTH-1:0] a2 [SECTION_COUNT]
);
    // Constant ROM keeps every section coefficient available in parallel.
    `include `BASE_PLAN_L1_09_V2_COEFF_RESET_SVH

    assign coeffs_ready = reset_n;

    generate
        for (genvar sec = 0; sec < SECTION_COUNT; sec++) begin : gen_coeff_rom
            assign a1[sec] = L1_09_A1_COEFF_ROM[sec];
            assign a2[sec] = L1_09_A2_COEFF_ROM[sec];
        end
    endgenerate
endmodule

module l1_09_v2_parallel_section #(
    parameter int DATA_W          = DATA_WIDTH_DEFAULT,
    parameter int COEFF_W         = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACC_W           = ACCUM_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic                         clear,
    input  logic                         stage_en,
    input  logic signed [DATA_W-1:0]     x_in [PARALLEL_FACTOR],
    input  logic signed [COEFF_W-1:0]    a1,
    input  logic signed [COEFF_W-1:0]    a2,
    output logic signed [DATA_W-1:0]     y_out [PARALLEL_FACTOR]
);
    localparam int MULT_W = DATA_W + COEFF_W;
    localparam int LAST_LANE = PARALLEL_FACTOR - 1;
    localparam int PREV_LANE = PARALLEL_FACTOR - 2;

    logic signed [DATA_W-1:0] x1;
    logic signed [DATA_W-1:0] x2;
    logic signed [DATA_W-1:0] y1;
    logic signed [DATA_W-1:0] y2;
    logic signed [DATA_W-1:0] x0_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] x1_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] x2_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y1_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y2_sel [PARALLEL_FACTOR];
    logic signed [DATA_W-1:0] y_next [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x0_a2 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x1_a1 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_x2_unity [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_y1_a1 [PARALLEL_FACTOR];
    logic signed [MULT_W-1:0] prod_y2_a2 [PARALLEL_FACTOR];
    logic signed [ACC_W-1:0]  acc [PARALLEL_FACTOR];

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
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            x0_sel[lane] = x_in[lane];
            if (lane == 0) begin
                x1_sel[lane] = x1;
                x2_sel[lane] = x2;
                y1_sel[lane] = y1;
                y2_sel[lane] = y2;
            end else if (lane == 1) begin
                x1_sel[lane] = x_in[0];
                x2_sel[lane] = x1;
                y1_sel[lane] = y_next[0];
                y2_sel[lane] = y1;
            end else begin
                x1_sel[lane] = x_in[lane - 1];
                x2_sel[lane] = x_in[lane - 2];
                y1_sel[lane] = y_next[lane - 1];
                y2_sel[lane] = y_next[lane - 2];
            end

            prod_x0_a2[lane]    = x0_sel[lane] * a2;
            prod_x1_a1[lane]    = x1_sel[lane] * a1;
            prod_x2_unity[lane] = {{COEFF_W{x2_sel[lane][DATA_W-1]}}, x2_sel[lane]} <<< COEFF_FRAC_BITS;
            prod_y1_a1[lane]    = y1_sel[lane] * a1;
            prod_y2_a2[lane]    = y2_sel[lane] * a2;
            acc[lane] = sign_extend_prod(prod_x0_a2[lane])
                      + sign_extend_prod(prod_x1_a1[lane])
                      + sign_extend_prod(prod_x2_unity[lane])
                      - sign_extend_prod(prod_y1_a1[lane])
                      - sign_extend_prod(prod_y2_a2[lane]);
            y_next[lane] = round_sat_qx(acc[lane]);
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            x1 <= '0;
            x2 <= '0;
            y1 <= '0;
            y2 <= '0;
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_out[lane] <= '0;
            end
        end else if (stage_en) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_out[lane] <= y_next[lane];
            end

            x1 <= x_in[LAST_LANE];
            y1 <= y_next[LAST_LANE];
            x2 <= x_in[PREV_LANE];
            y2 <= y_next[PREV_LANE];
        end
    end
endmodule

module l1_09_v2_parallel_core #(
    parameter int SECTION_COUNT   = SECTION_COUNT_DEFAULT,
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH     = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH     = ACCUM_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT
) (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              clear,
    input  logic                              enable,
    input  logic signed [DATA_WIDTH-1:0]      x_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0]      x_q [PARALLEL_FACTOR],
    input  logic                              in_valid,
    output logic                              input_ready,
    output logic signed [DATA_WIDTH-1:0]      y_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0]      y_q [PARALLEL_FACTOR],
    output logic [PARALLEL_FACTOR-1:0]        y_valid,
    output logic                              coeffs_ready
);
    logic signed [COEFF_WIDTH-1:0] coeff_a1 [SECTION_COUNT];
    logic signed [COEFF_WIDTH-1:0] coeff_a2 [SECTION_COUNT];
    logic signed [DATA_WIDTH-1:0]  stage_i [SECTION_COUNT+1][PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0]  stage_q [SECTION_COUNT+1][PARALLEL_FACTOR];
    logic [SECTION_COUNT:0]        stage_valid;
    logic                          run_valid;

    assign input_ready = enable && coeffs_ready && !clear;
    assign run_valid = in_valid
                     && input_ready;
    assign stage_valid[0] = run_valid;

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            stage_i[0][lane] = x_i[lane];
            stage_q[0][lane] = x_q[lane];
        end
    end

    l1_09_v2_coeff_bank #(
        .SECTION_COUNT(SECTION_COUNT),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) u_coeff_bank (
        .reset_n(reset_n),
        .coeffs_ready(coeffs_ready),
        .a1(coeff_a1),
        .a2(coeff_a2)
    );

    generate
        for (genvar sec = 0; sec < SECTION_COUNT; sec++) begin : gen_sections
            l1_09_v2_parallel_section #(
                .DATA_W(DATA_WIDTH),
                .COEFF_W(COEFF_WIDTH),
                .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
                .ACC_W(ACCUM_WIDTH),
                .PARALLEL_FACTOR(PARALLEL_FACTOR)
            ) u_i_section (
                .clk(clk),
                .reset_n(reset_n),
                .clear(clear),
                .stage_en(enable && stage_valid[sec]),
                .x_in(stage_i[sec]),
                .a1(coeff_a1[sec]),
                .a2(coeff_a2[sec]),
                .y_out(stage_i[sec + 1])
            );

            l1_09_v2_parallel_section #(
                .DATA_W(DATA_WIDTH),
                .COEFF_W(COEFF_WIDTH),
                .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
                .ACC_W(ACCUM_WIDTH),
                .PARALLEL_FACTOR(PARALLEL_FACTOR)
            ) u_q_section (
                .clk(clk),
                .reset_n(reset_n),
                .clear(clear),
                .stage_en(enable && stage_valid[sec]),
                .x_in(stage_q[sec]),
                .a1(coeff_a1[sec]),
                .a2(coeff_a2[sec]),
                .y_out(stage_q[sec + 1])
            );
        end
    endgenerate

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            for (int sec = 1; sec <= SECTION_COUNT; sec++) begin
                stage_valid[sec] <= 1'b0;
            end
        end else if (enable) begin
            for (int sec = 1; sec <= SECTION_COUNT; sec++) begin
                stage_valid[sec] <= stage_valid[sec - 1];
            end
        end
    end

    always_comb begin
        y_valid = '0;
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            y_i[lane] = '0;
            y_q[lane] = '0;
        end

        if (stage_valid[SECTION_COUNT]) begin
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                y_i[lane]     = stage_i[SECTION_COUNT][lane];
                y_q[lane]     = stage_q[SECTION_COUNT][lane];
                y_valid[lane] = 1'b1;
            end
        end
    end
endmodule

`default_nettype wire
