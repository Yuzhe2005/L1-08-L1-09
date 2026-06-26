`default_nettype none

import base_plan_l1_08_v2_pkg::*;

module l1_08_v2_top #(
    parameter int TAP_NUM          = TAP_NUM_DEFAULT,
    parameter int DATA_WIDTH       = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH      = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS  = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH      = ACCUM_WIDTH_DEFAULT,
    parameter int MAC_LATENCY      = MAC_LATENCY_DEFAULT,
    parameter int PARALLEL_FACTOR  = PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W   = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1)
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  l1_08_mode_e                  mode,
    input  logic signed [DATA_WIDTH-1:0] x_i,
    input  logic signed [DATA_WIDTH-1:0] x_q,
    input  logic signed [DATA_WIDTH-1:0] parallel_x_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0] parallel_x_q [PARALLEL_FACTOR],
    input  logic [ACTIVE_LANES_W-1:0]    parallel_active_lanes,
    input  logic                         in_valid,
    input  logic                         bypass,
    output logic signed [DATA_WIDTH-1:0] y_i,
    output logic signed [DATA_WIDTH-1:0] y_q,
    output logic                         y_valid,
    output logic signed [DATA_WIDTH-1:0] parallel_y_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0] parallel_y_q [PARALLEL_FACTOR],
    output logic [PARALLEL_FACTOR-1:0]   parallel_y_valid,
    output logic                         coeffs_ready,
    output logic                         mode_supported,
    output logic                         mode_error
);
    logic single_mode;
    logic parallel_mode;
    logic single_in_valid;
    logic parallel_in_valid;
    logic signed [DATA_WIDTH-1:0] single_y_i;
    logic signed [DATA_WIDTH-1:0] single_y_q;
    logic single_y_valid;
    logic single_coeffs_ready;
    logic single_clear;
    logic signed [DATA_WIDTH-1:0] parallel_core_y_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] parallel_core_y_q [PARALLEL_FACTOR];
    logic [PARALLEL_FACTOR-1:0] parallel_core_y_valid;
    logic parallel_coeffs_ready;
    logic parallel_clear;
    logic parallel_active_lanes_error;

    assign single_mode       = (mode == L1_08_MODE_SINGLE);
    assign parallel_mode     = (mode == L1_08_MODE_PARALLEL);
    assign single_in_valid   = in_valid && single_mode;
    assign parallel_in_valid = in_valid && parallel_mode;
    assign single_clear      = !single_mode;
    assign parallel_clear    = !parallel_mode;
    assign mode_supported    = single_mode || parallel_mode;
    assign mode_error        = (in_valid && !mode_supported)
                             || (parallel_mode && in_valid && parallel_active_lanes_error);
    assign coeffs_ready   = single_mode   ? single_coeffs_ready
                          : parallel_mode ? parallel_coeffs_ready
                          : 1'b0;

    l1_08_v2_core_single #(
        .TAP_NUM(TAP_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .MAC_LATENCY(MAC_LATENCY)
    ) u_single_core (
        .clk(clk),
        .reset_n(reset_n),
        .clear(single_clear),
        .x_i(x_i),
        .x_q(x_q),
        .in_valid(single_in_valid),
        .bypass(bypass),
        .y_i(single_y_i),
        .y_q(single_y_q),
        .y_valid(single_y_valid),
        .coeffs_ready(single_coeffs_ready)
    );

    l1_08_v2_core_parallel #(
        .TAP_NUM(TAP_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS),
        .ACCUM_WIDTH(ACCUM_WIDTH),
        .MAC_LATENCY(MAC_LATENCY),
        .PARALLEL_FACTOR(PARALLEL_FACTOR),
        .ACTIVE_LANES_W(ACTIVE_LANES_W)
    ) u_parallel_core (
        .clk(clk),
        .reset_n(reset_n),
        .clear(parallel_clear),
        .x_i(parallel_x_i),
        .x_q(parallel_x_q),
        .active_lanes(parallel_active_lanes),
        .in_valid(parallel_in_valid),
        .bypass(bypass),
        .y_i(parallel_core_y_i),
        .y_q(parallel_core_y_q),
        .y_valid(parallel_core_y_valid),
        .coeffs_ready(parallel_coeffs_ready),
        .active_lanes_error(parallel_active_lanes_error)
    );

    always_comb begin
        y_i     = '0;
        y_q     = '0;
        y_valid = 1'b0;
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            parallel_y_i[lane]     = '0;
            parallel_y_q[lane]     = '0;
            parallel_y_valid[lane] = 1'b0;
        end

        unique case (mode)
            L1_08_MODE_SINGLE: begin
                y_i     = single_y_i;
                y_q     = single_y_q;
                y_valid = single_y_valid;
            end

            L1_08_MODE_PARALLEL: begin
                for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                    parallel_y_i[lane]     = parallel_core_y_i[lane];
                    parallel_y_q[lane]     = parallel_core_y_q[lane];
                    parallel_y_valid[lane] = parallel_core_y_valid[lane];
                end
            end

            L1_08_MODE_BUFFERED: begin
                y_i     = '0;
                y_q     = '0;
                y_valid = 1'b0;
            end

            default: begin
                y_i     = '0;
                y_q     = '0;
                y_valid = 1'b0;
            end
        endcase
    end
endmodule

`default_nettype wire
