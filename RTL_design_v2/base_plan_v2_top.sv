`default_nettype none

module base_plan_v2_top #(
    parameter int TAP_NUM                  = base_plan_l1_08_v2_pkg::TAP_NUM_DEFAULT,
    parameter int DATA_WIDTH               = base_plan_l1_08_v2_pkg::DATA_WIDTH_DEFAULT,
    parameter int L1_08_COEFF_WIDTH        = base_plan_l1_08_v2_pkg::COEFF_WIDTH_DEFAULT,
    parameter int L1_08_COEFF_FRAC_BITS    = base_plan_l1_08_v2_pkg::COEFF_FRAC_BITS_DEFAULT,
    parameter int L1_08_ACCUM_WIDTH        = DATA_WIDTH
                                           + L1_08_COEFF_WIDTH
                                           + base_plan_l1_08_v2_pkg::ACCUM_EXTRA_BITS_DEFAULT,
    parameter int L1_08_MAC_LATENCY        = base_plan_l1_08_v2_pkg::MAC_LATENCY_DEFAULT,
    parameter int L1_09_SECTION_COUNT      = base_plan_l1_09_v2_pkg::SECTION_COUNT_DEFAULT,
    parameter int L1_09_COEFF_WIDTH        = base_plan_l1_09_v2_pkg::COEFF_WIDTH_DEFAULT,
    parameter int L1_09_COEFF_FRAC_BITS    = base_plan_l1_09_v2_pkg::COEFF_FRAC_BITS_DEFAULT,
    parameter int L1_09_ACCUM_WIDTH        = DATA_WIDTH
                                           + L1_09_COEFF_WIDTH
                                           + base_plan_l1_09_v2_pkg::ACCUM_EXTRA_BITS_DEFAULT,
    parameter int PARALLEL_FACTOR          = base_plan_l1_08_v2_pkg::PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W           = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1),
    parameter int INPUT_BUFFER_DEPTH       = base_plan_l1_08_v2_pkg::INPUT_BUFFER_DEPTH_DEFAULT,
    parameter int OUTPUT_BUFFER_DEPTH      = 1024
) (
    input  logic                                      clk,
    input  logic                                      reset_n,
    input  logic                                      sample_clk,
    input  logic                                      sample_reset_n,
    input  logic                                      output_clk,
    input  logic                                      output_reset_n,
    input  base_plan_l1_08_v2_pkg::l1_08_mode_e      mode,
    input  logic signed [DATA_WIDTH-1:0]              x_i,
    input  logic signed [DATA_WIDTH-1:0]              x_q,
    input  logic signed [DATA_WIDTH-1:0]              parallel_x_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0]              parallel_x_q [PARALLEL_FACTOR],
    input  logic [ACTIVE_LANES_W-1:0]                 parallel_active_lanes,
    input  logic                                      in_valid,
    output logic                                      input_ready,
    output logic signed [DATA_WIDTH-1:0]              y_i,
    output logic signed [DATA_WIDTH-1:0]              y_q,
    output logic                                      y_valid,
    input  logic                                      y_ready,
    output logic                                      coeffs_ready,
    output logic                                      mode_supported,
    output logic                                      mode_error,
    output logic                                      input_buffer_overflow_error,
    output logic                                      output_buffer_overflow_error
);
    localparam logic [ACTIVE_LANES_W-1:0] FullActiveLanes = ACTIVE_LANES_W'(PARALLEL_FACTOR);

    logic single_mode;
    logic parallel_mode;
    logic buffered_mode;
    logic parallel_path_mode;
    logic parallel_full_bundle;

    logic signed [DATA_WIDTH-1:0] l1_08_single_y_i;
    logic signed [DATA_WIDTH-1:0] l1_08_single_y_q;
    logic                         l1_08_single_y_valid;
    logic                         l1_08_single_coeffs_ready;
    logic                         l1_08_single_clear;

    logic signed [DATA_WIDTH-1:0] l1_09_single_y_i;
    logic signed [DATA_WIDTH-1:0] l1_09_single_y_q;
    logic                         l1_09_single_y_valid;
    logic                         l1_09_single_coeffs_ready;
    logic                         l1_09_single_clear;

    logic signed [DATA_WIDTH-1:0] single_output_buffer_in_i [1];
    logic signed [DATA_WIDTH-1:0] single_output_buffer_in_q [1];
    logic signed [DATA_WIDTH-1:0] single_output_i;
    logic signed [DATA_WIDTH-1:0] single_output_q;
    logic                         single_output_valid;
    logic                         single_output_ready;
    logic                         single_output_overflow_error;
    logic                         single_output_wr_clear;
    logic                         single_output_rd_clear;

    logic                         input_buffer_clear;
    logic                         input_buffer_wr_clear_sync1;
    logic                         input_buffer_wr_clear_sync2;
    logic                         input_buffer_in_ready;
    logic signed [DATA_WIDTH-1:0] input_buffer_out_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] input_buffer_out_q [PARALLEL_FACTOR];
    logic                         input_buffer_out_valid;
    logic                         input_buffer_out_ready;
    logic                         input_buffer_overflow_error_wr;
    logic                         input_buffer_overflow_sync1;
    logic                         input_buffer_overflow_sync2;

    logic signed [DATA_WIDTH-1:0] l1_08_parallel_x_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] l1_08_parallel_x_q [PARALLEL_FACTOR];
    logic [ACTIVE_LANES_W-1:0]    l1_08_parallel_active_lanes;
    logic                         l1_08_parallel_in_valid;
    logic                         l1_08_parallel_input_ready;
    logic signed [DATA_WIDTH-1:0] l1_08_parallel_y_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] l1_08_parallel_y_q [PARALLEL_FACTOR];
    logic [PARALLEL_FACTOR-1:0]   l1_08_parallel_y_valid;
    logic                         l1_08_parallel_coeffs_ready;
    logic                         l1_08_parallel_active_lanes_error;
    logic                         l1_08_parallel_clear;

    logic                         l1_09_parallel_in_valid;
    logic                         l1_09_parallel_input_ready;
    logic signed [DATA_WIDTH-1:0] l1_09_parallel_y_i [PARALLEL_FACTOR];
    logic signed [DATA_WIDTH-1:0] l1_09_parallel_y_q [PARALLEL_FACTOR];
    logic [PARALLEL_FACTOR-1:0]   l1_09_parallel_y_valid;
    logic                         l1_09_parallel_coeffs_ready;
    logic                         l1_09_parallel_clear;

    logic signed [DATA_WIDTH-1:0] parallel_output_i;
    logic signed [DATA_WIDTH-1:0] parallel_output_q;
    logic                         parallel_output_valid;
    logic                         parallel_output_ready;
    logic                         parallel_output_overflow_error;
    logic                         parallel_output_wr_clear;
    logic                         parallel_output_rd_clear;

    logic                         single_mode_output_sync1;
    logic                         single_mode_output_sync2;
    logic                         parallel_path_output_sync1;
    logic                         parallel_path_output_sync2;

    assign single_mode = (mode == base_plan_l1_08_v2_pkg::L1_08_MODE_SINGLE);
    assign parallel_mode = (mode == base_plan_l1_08_v2_pkg::L1_08_MODE_PARALLEL);
    assign buffered_mode = (mode == base_plan_l1_08_v2_pkg::L1_08_MODE_BUFFERED);
    assign parallel_path_mode = parallel_mode || buffered_mode;
    assign parallel_full_bundle = (parallel_active_lanes == FullActiveLanes);
    assign mode_supported = single_mode || parallel_mode || buffered_mode;

    assign l1_08_single_clear = !single_mode;
    assign l1_09_single_clear = !single_mode;
    assign input_buffer_clear = !buffered_mode;
    assign l1_08_parallel_clear = !parallel_path_mode;
    assign l1_09_parallel_clear = !parallel_path_mode;
    assign single_output_wr_clear = !single_mode;
    assign parallel_output_wr_clear = !parallel_path_mode;

    assign coeffs_ready = single_mode ? (l1_08_single_coeffs_ready && l1_09_single_coeffs_ready)
                        : parallel_path_mode ? (l1_08_parallel_coeffs_ready && l1_09_parallel_coeffs_ready)
                        : 1'b0;

    assign input_ready = single_mode ? (l1_08_single_coeffs_ready && l1_09_single_coeffs_ready)
                       : parallel_mode ? (parallel_full_bundle
                                       && l1_08_parallel_input_ready
                                       && l1_09_parallel_input_ready)
                       : buffered_mode ? (!input_buffer_wr_clear_sync2 && input_buffer_in_ready)
                       : 1'b0;

    assign mode_error = (in_valid && !mode_supported)
                     || (parallel_mode && in_valid && !parallel_full_bundle)
                     || (parallel_mode && in_valid && l1_08_parallel_active_lanes_error)
                     || (buffered_mode && in_valid && !input_buffer_in_ready)
                     || input_buffer_overflow_error
                     || output_buffer_overflow_error;

    assign l1_08_parallel_in_valid = (parallel_mode && in_valid
                                   && parallel_full_bundle
                                   && l1_09_parallel_input_ready)
                                  || (buffered_mode
                                   && input_buffer_out_valid
                                   && l1_09_parallel_input_ready);
    assign l1_09_parallel_in_valid = parallel_path_mode && (&l1_08_parallel_y_valid);
    assign input_buffer_out_ready = buffered_mode
                                  && l1_08_parallel_input_ready
                                  && l1_09_parallel_input_ready;

    assign single_output_buffer_in_i[0] = l1_09_single_y_i;
    assign single_output_buffer_in_q[0] = l1_09_single_y_q;
    assign output_buffer_overflow_error = single_output_overflow_error
                                       || parallel_output_overflow_error;

    always_ff @(posedge sample_clk or negedge sample_reset_n) begin
        if (!sample_reset_n) begin
            input_buffer_wr_clear_sync1 <= 1'b1;
            input_buffer_wr_clear_sync2 <= 1'b1;
        end else begin
            input_buffer_wr_clear_sync1 <= input_buffer_clear;
            input_buffer_wr_clear_sync2 <= input_buffer_wr_clear_sync1;
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            input_buffer_overflow_sync1 <= 1'b0;
            input_buffer_overflow_sync2 <= 1'b0;
            input_buffer_overflow_error <= 1'b0;
        end else begin
            input_buffer_overflow_sync1 <= input_buffer_overflow_error_wr;
            input_buffer_overflow_sync2 <= input_buffer_overflow_sync1;
            input_buffer_overflow_error <= input_buffer_overflow_sync2;
        end
    end

    always_ff @(posedge output_clk or negedge output_reset_n) begin
        if (!output_reset_n) begin
            single_mode_output_sync1   <= 1'b0;
            single_mode_output_sync2   <= 1'b0;
            parallel_path_output_sync1 <= 1'b0;
            parallel_path_output_sync2 <= 1'b0;
        end else begin
            single_mode_output_sync1   <= single_mode;
            single_mode_output_sync2   <= single_mode_output_sync1;
            parallel_path_output_sync1 <= parallel_path_mode;
            parallel_path_output_sync2 <= parallel_path_output_sync1;
        end
    end

    assign single_output_rd_clear = !single_mode_output_sync2;
    assign parallel_output_rd_clear = !parallel_path_output_sync2;
    assign single_output_ready = single_mode_output_sync2 && y_ready;
    assign parallel_output_ready = parallel_path_output_sync2 && y_ready;

    always_comb begin
        y_i = '0;
        y_q = '0;
        y_valid = 1'b0;

        if (single_mode_output_sync2) begin
            y_i = single_output_i;
            y_q = single_output_q;
            y_valid = single_output_valid;
        end else if (parallel_path_output_sync2) begin
            y_i = parallel_output_i;
            y_q = parallel_output_q;
            y_valid = parallel_output_valid;
        end
    end

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            l1_08_parallel_x_i[lane] = buffered_mode ? input_buffer_out_i[lane] : parallel_x_i[lane];
            l1_08_parallel_x_q[lane] = buffered_mode ? input_buffer_out_q[lane] : parallel_x_q[lane];
        end
    end

    assign l1_08_parallel_active_lanes = buffered_mode ? FullActiveLanes : parallel_active_lanes;

    l1_08_v2_core_single #(
        .TAP_NUM(TAP_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(L1_08_COEFF_WIDTH),
        .COEFF_FRAC_BITS(L1_08_COEFF_FRAC_BITS),
        .ACCUM_WIDTH(L1_08_ACCUM_WIDTH),
        .MAC_LATENCY(L1_08_MAC_LATENCY)
    ) u_l1_08_single (
        .clk(clk),
        .reset_n(reset_n),
        .clear(l1_08_single_clear),
        .x_i(x_i),
        .x_q(x_q),
        .in_valid(in_valid && single_mode && l1_09_single_coeffs_ready),
        .y_i(l1_08_single_y_i),
        .y_q(l1_08_single_y_q),
        .y_valid(l1_08_single_y_valid),
        .coeffs_ready(l1_08_single_coeffs_ready)
    );

    l1_09_v2_single_core #(
        .SECTION_COUNT(L1_09_SECTION_COUNT),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(L1_09_COEFF_WIDTH),
        .COEFF_FRAC_BITS(L1_09_COEFF_FRAC_BITS),
        .ACCUM_WIDTH(L1_09_ACCUM_WIDTH)
    ) u_l1_09_single (
        .clk(clk),
        .reset_n(reset_n),
        .clear(l1_09_single_clear),
        .l1_08_y_i(l1_08_single_y_i),
        .l1_08_y_q(l1_08_single_y_q),
        .l1_08_y_valid(l1_08_single_y_valid),
        .y_i(l1_09_single_y_i),
        .y_q(l1_09_single_y_q),
        .y_valid(l1_09_single_y_valid),
        .coeffs_ready(l1_09_single_coeffs_ready)
    );

    l1_09_v2_output_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .PARALLEL_FACTOR(1),
        .BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH)
    ) u_single_output_buffer (
        .wr_clk(clk),
        .wr_reset_n(reset_n),
        .wr_clear(single_output_wr_clear),
        .in_i(single_output_buffer_in_i),
        .in_q(single_output_buffer_in_q),
        .in_valid(l1_09_single_y_valid),
        .in_ready(),
        .rd_clk(output_clk),
        .rd_reset_n(output_reset_n),
        .rd_clear(single_output_rd_clear),
        .out_i(single_output_i),
        .out_q(single_output_q),
        .out_valid(single_output_valid),
        .out_ready(single_output_ready),
        .overflow_error(single_output_overflow_error)
    );

    l1_08_v2_input_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .PARALLEL_FACTOR(PARALLEL_FACTOR),
        .BUFFER_DEPTH(INPUT_BUFFER_DEPTH)
    ) u_input_buffer (
        .wr_clk(sample_clk),
        .wr_reset_n(sample_reset_n),
        .wr_clear(input_buffer_wr_clear_sync2),
        .in_i(x_i),
        .in_q(x_q),
        .in_valid(in_valid && !input_buffer_wr_clear_sync2),
        .in_ready(input_buffer_in_ready),
        .rd_clk(clk),
        .rd_reset_n(reset_n),
        .rd_clear(input_buffer_clear),
        .out_i(input_buffer_out_i),
        .out_q(input_buffer_out_q),
        .out_valid(input_buffer_out_valid),
        .out_ready(input_buffer_out_ready),
        .overflow_error(input_buffer_overflow_error_wr)
    );

    l1_08_v2_core_parallel #(
        .TAP_NUM(TAP_NUM),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(L1_08_COEFF_WIDTH),
        .COEFF_FRAC_BITS(L1_08_COEFF_FRAC_BITS),
        .ACCUM_WIDTH(L1_08_ACCUM_WIDTH),
        .MAC_LATENCY(L1_08_MAC_LATENCY),
        .PARALLEL_FACTOR(PARALLEL_FACTOR),
        .ACTIVE_LANES_W(ACTIVE_LANES_W)
    ) u_l1_08_parallel (
        .clk(clk),
        .reset_n(reset_n),
        .clear(l1_08_parallel_clear),
        .x_i(l1_08_parallel_x_i),
        .x_q(l1_08_parallel_x_q),
        .active_lanes(l1_08_parallel_active_lanes),
        .in_valid(l1_08_parallel_in_valid),
        .input_ready(l1_08_parallel_input_ready),
        .y_i(l1_08_parallel_y_i),
        .y_q(l1_08_parallel_y_q),
        .y_valid(l1_08_parallel_y_valid),
        .coeffs_ready(l1_08_parallel_coeffs_ready),
        .active_lanes_error(l1_08_parallel_active_lanes_error)
    );

    l1_09_v2_parallel_core #(
        .SECTION_COUNT(L1_09_SECTION_COUNT),
        .DATA_WIDTH(DATA_WIDTH),
        .COEFF_WIDTH(L1_09_COEFF_WIDTH),
        .COEFF_FRAC_BITS(L1_09_COEFF_FRAC_BITS),
        .ACCUM_WIDTH(L1_09_ACCUM_WIDTH),
        .PARALLEL_FACTOR(PARALLEL_FACTOR)
    ) u_l1_09_parallel (
        .clk(clk),
        .reset_n(reset_n),
        .clear(l1_09_parallel_clear),
        .x_i(l1_08_parallel_y_i),
        .x_q(l1_08_parallel_y_q),
        .in_valid(l1_09_parallel_in_valid),
        .input_ready(l1_09_parallel_input_ready),
        .y_i(l1_09_parallel_y_i),
        .y_q(l1_09_parallel_y_q),
        .y_valid(l1_09_parallel_y_valid),
        .coeffs_ready(l1_09_parallel_coeffs_ready)
    );

    l1_09_v2_output_buffer #(
        .DATA_WIDTH(DATA_WIDTH),
        .PARALLEL_FACTOR(PARALLEL_FACTOR),
        .BUFFER_DEPTH(OUTPUT_BUFFER_DEPTH)
    ) u_parallel_output_buffer (
        .wr_clk(clk),
        .wr_reset_n(reset_n),
        .wr_clear(parallel_output_wr_clear),
        .in_i(l1_09_parallel_y_i),
        .in_q(l1_09_parallel_y_q),
        .in_valid(&l1_09_parallel_y_valid),
        .in_ready(),
        .rd_clk(output_clk),
        .rd_reset_n(output_reset_n),
        .rd_clear(parallel_output_rd_clear),
        .out_i(parallel_output_i),
        .out_q(parallel_output_q),
        .out_valid(parallel_output_valid),
        .out_ready(parallel_output_ready),
        .overflow_error(parallel_output_overflow_error)
    );
endmodule

`default_nettype wire
