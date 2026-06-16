`default_nettype none

// Base Plan full-chain top: L1-08 FIR compensation followed by L1-09 all-pass IIR.

import base_plan_l1_08_pkg::*;

module base_plan_top #(
    parameter int TAP_NUM                  = TAP_NUM_DEFAULT,
    parameter int DATA_WIDTH               = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH              = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS          = COEFF_FRAC_BITS_DEFAULT,
    parameter int L1_09_SECTION_COUNT      = base_plan_l1_09_pkg::SECTION_COUNT_DEFAULT,
    parameter int L1_09_COEFF_WIDTH        = base_plan_l1_09_pkg::COEFF_WIDTH_DEFAULT,
    parameter int L1_09_COEFF_FRAC_BITS    = base_plan_l1_09_pkg::COEFF_FRAC_BITS_DEFAULT
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic signed [DATA_WIDTH-1:0] i_in,
    input  logic signed [DATA_WIDTH-1:0] q_in,
    input  logic                         in_valid,
    input  logic                         l1_08_bypass,
    input  logic                         l1_09_bypass,
    output logic signed [DATA_WIDTH-1:0] o_i,
    output logic signed [DATA_WIDTH-1:0] o_q,
    output logic                         o_valid
);
    logic signed [DATA_WIDTH-1:0] l1_08_o_i;
    logic signed [DATA_WIDTH-1:0] l1_08_o_q;
    logic                         l1_08_o_valid;

    L1_08 #(
        .TAP_NUM(TAP_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(COEFF_WIDTH),
        .COEFF_FRAC_BITS(COEFF_FRAC_BITS)
    ) u_l1_08 (
        .clk(clk),
        .reset_n(reset_n),
        .i_in(i_in),
        .q_in(q_in),
        .in_valid(in_valid),
        .o_i(l1_08_o_i),
        .o_q(l1_08_o_q),
        .o_valid(l1_08_o_valid),
        .bypass(l1_08_bypass)
    );

    L1_09 #(
        .SECTION_COUNT(L1_09_SECTION_COUNT),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(L1_09_COEFF_WIDTH),
        .COEFF_FRAC_BITS(L1_09_COEFF_FRAC_BITS)
    ) u_l1_09 (
        .clk(clk),
        .reset_n(reset_n),
        .i_in(l1_08_o_i),
        .q_in(l1_08_o_q),
        .in_valid(l1_08_o_valid),
        .o_i(o_i),
        .o_q(o_q),
        .o_valid(o_valid),
        .bypass(l1_09_bypass)
    );
endmodule
