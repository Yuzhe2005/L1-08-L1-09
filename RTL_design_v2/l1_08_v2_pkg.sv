`default_nettype none

package base_plan_l1_08_v2_pkg;
    typedef enum logic [1:0] {
        L1_08_MODE_SINGLE   = 2'd0,
        L1_08_MODE_PARALLEL = 2'd1,
        L1_08_MODE_BUFFERED = 2'd2
    } l1_08_mode_e;

    localparam int TAP_NUM_DEFAULT          = 80;
    localparam int GROUP_DELAY_SAMPLES      = (TAP_NUM_DEFAULT - 1) / 2;
    localparam int FIR_SETTLE_SAMPLES       = TAP_NUM_DEFAULT - 1;

    localparam int DATA_WIDTH_DEFAULT       = 16;
    localparam int COEFF_WIDTH_DEFAULT      = 16;
    localparam int COEFF_FRAC_BITS_DEFAULT  = 13;
    localparam int COEFF_TOTAL_BITS_DEFAULT = 16;
    localparam int ACCUM_EXTRA_BITS_DEFAULT = 7;
    localparam int ACCUM_WIDTH_DEFAULT      = DATA_WIDTH_DEFAULT
                                            + COEFF_WIDTH_DEFAULT
                                            + ACCUM_EXTRA_BITS_DEFAULT;
    localparam int MAC_LATENCY_DEFAULT      = 7;
    localparam int SINGLE_OUTPUT_LATENCY    = MAC_LATENCY_DEFAULT;
    localparam int PARALLEL_FACTOR_DEFAULT  = 4;
    localparam int INPUT_BUFFER_DEPTH_DEFAULT = 1024;
endpackage

`ifndef BASE_PLAN_L1_08_V2_COEFF_RESET_SVH
`define BASE_PLAN_L1_08_V2_COEFF_RESET_SVH "coeff/l1_08_fir_coeff_reset.svh"
`endif

`default_nettype wire
