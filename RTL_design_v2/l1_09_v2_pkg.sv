`default_nettype none

package base_plan_l1_09_v2_pkg;

    localparam int SECTION_COUNT_DEFAULT      = 64;
    localparam int DATA_WIDTH_DEFAULT         = 16;
    localparam int COEFF_WIDTH_DEFAULT        = 18;
    localparam int COEFF_FRAC_BITS_DEFAULT    = 15;
    localparam int ACCUM_EXTRA_BITS_DEFAULT   = 3;
    localparam int ACCUM_WIDTH_DEFAULT =
        DATA_WIDTH_DEFAULT + COEFF_WIDTH_DEFAULT + ACCUM_EXTRA_BITS_DEFAULT;
    localparam int PARALLEL_FACTOR_DEFAULT    = 4;
    localparam int IIR_LATENCY_DEFAULT        = SECTION_COUNT_DEFAULT;

endpackage

`ifndef BASE_PLAN_L1_09_V2_COEFF_RESET_SVH
`define BASE_PLAN_L1_09_V2_COEFF_RESET_SVH "coeff/l1_09_allpass_coeff_reset.svh"
`endif

`default_nettype wire
