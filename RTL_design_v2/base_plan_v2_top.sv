`default_nettype none

typedef enum logic {
    BASE_PLAN_V2_MODE_SINGLE            = 1'b0,
    BASE_PLAN_V2_MODE_BUFFERED_PARALLEL = 1'b1
} base_plan_v2_mode_e;

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
    input  base_plan_v2_mode_e                       mode,
    input  logic signed [DATA_WIDTH-1:0]              x_i,
    input  logic signed [DATA_WIDTH-1:0]              x_q,
    input  logic                                      in_valid,
    output logic                                      input_ready,
    output logic signed [DATA_WIDTH-1:0]              y_i,
    output logic signed [DATA_WIDTH-1:0]              y_q,
    output logic                                      y_valid,
    input  logic                                      y_ready,
    output logic                                      coeffs_ready,
    output logic                                      mode_error,
    output logic                                      input_buffer_overflow_error,
    output logic                                      output_buffer_overflow_error
);
    localparam logic [ACTIVE_LANES_W-1:0] FullActiveLanes = ACTIVE_LANES_W'(PARALLEL_FACTOR);

    base_plan_v2_mode_e mode_active;
    logic mode_locked;
    logic mode_change_error;
    logic single_mode;
    logic buffered_parallel_mode;
    logic single_chain_enable;
    logic parallel_chain_enable;
    logic parallel_output_bundle_valid;

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
    logic                         parallel_output_buffer_in_ready;
    logic                         parallel_output_buffer_write_valid;
    logic                         parallel_output_overflow_error;
    logic                         parallel_output_wr_clear;
    logic                         parallel_output_rd_clear;

    logic                         parallel_path_output_sync1;
    logic                         parallel_path_output_sync2;

    assign single_mode = mode_locked && (mode_active == BASE_PLAN_V2_MODE_SINGLE);
    assign buffered_parallel_mode = mode_locked && (mode_active == BASE_PLAN_V2_MODE_BUFFERED_PARALLEL);
    assign single_chain_enable = single_mode
                              && (!l1_09_single_y_valid || y_ready);
    assign parallel_output_bundle_valid = &l1_09_parallel_y_valid;
    assign parallel_chain_enable = buffered_parallel_mode
                                && (!parallel_output_bundle_valid || parallel_output_buffer_in_ready);

    assign l1_08_single_clear = !single_mode;
    assign l1_09_single_clear = !single_mode;
    assign input_buffer_clear = !buffered_parallel_mode;
    assign l1_08_parallel_clear = !buffered_parallel_mode;
    assign l1_09_parallel_clear = !buffered_parallel_mode;
    assign parallel_output_wr_clear = !buffered_parallel_mode;

    always_comb begin
        coeffs_ready = 1'b0;

        if (single_mode) begin
            coeffs_ready = l1_08_single_coeffs_ready
                        && l1_09_single_coeffs_ready;
        end else if (buffered_parallel_mode) begin
            coeffs_ready = l1_08_parallel_coeffs_ready
                        && l1_09_parallel_coeffs_ready;
        end
    end

    always_comb begin
        input_ready = 1'b0;

        if (single_mode) begin
            input_ready = l1_08_single_coeffs_ready
                       && l1_09_single_coeffs_ready
                       && single_chain_enable;
        end else if (buffered_parallel_mode) begin
            input_ready = !input_buffer_wr_clear_sync2
                       && input_buffer_in_ready;
        end
    end

    assign mode_error = mode_change_error
                     || (buffered_parallel_mode && in_valid && !input_buffer_in_ready)
                     || l1_08_parallel_active_lanes_error
                     || input_buffer_overflow_error
                     || output_buffer_overflow_error;

    assign l1_08_parallel_in_valid = buffered_parallel_mode
                                  && parallel_chain_enable
                                  && input_buffer_out_valid
                                  && l1_09_parallel_input_ready;
    assign l1_09_parallel_in_valid = buffered_parallel_mode
                                  && parallel_chain_enable
                                  && l1_09_parallel_input_ready
                                  && (&l1_08_parallel_y_valid);
    assign input_buffer_out_ready = buffered_parallel_mode
                                  && parallel_chain_enable
                                  && l1_08_parallel_input_ready
                                  && l1_09_parallel_input_ready;

    assign output_buffer_overflow_error = parallel_output_overflow_error;
    assign parallel_output_buffer_write_valid = buffered_parallel_mode
                                             && parallel_output_bundle_valid
                                             && parallel_output_buffer_in_ready;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mode_active       <= BASE_PLAN_V2_MODE_SINGLE;
            mode_locked       <= 1'b0;
            mode_change_error <= 1'b0;
        end else if (!mode_locked) begin
            mode_active       <= mode;
            mode_locked       <= 1'b1;
            mode_change_error <= 1'b0;
        end else if (mode != mode_active) begin
            mode_change_error <= 1'b1;
        end
    end

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
            parallel_path_output_sync1 <= 1'b0;
            parallel_path_output_sync2 <= 1'b0;
        end else begin
            parallel_path_output_sync1 <= buffered_parallel_mode;
            parallel_path_output_sync2 <= parallel_path_output_sync1;
        end
    end

    assign parallel_output_rd_clear = !parallel_path_output_sync2;
    assign parallel_output_ready = parallel_path_output_sync2 && y_ready;

    always_comb begin
        y_i = '0;
        y_q = '0;
        y_valid = 1'b0;

        if (single_mode) begin
            y_i = l1_09_single_y_i;
            y_q = l1_09_single_y_q;
            y_valid = l1_09_single_y_valid;
        end else if (parallel_path_output_sync2) begin
            y_i = parallel_output_i;
            y_q = parallel_output_q;
            y_valid = parallel_output_valid;
        end
    end

    always_comb begin
        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            l1_08_parallel_x_i[lane] = input_buffer_out_i[lane];
            l1_08_parallel_x_q[lane] = input_buffer_out_q[lane];
        end
    end

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
        .enable(single_chain_enable),
        .x_i(x_i),
        .x_q(x_q),
        .in_valid(in_valid && input_ready),
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
        .enable(single_chain_enable),
        .l1_08_y_i(l1_08_single_y_i),
        .l1_08_y_q(l1_08_single_y_q),
        .l1_08_y_valid(l1_08_single_y_valid),
        .y_i(l1_09_single_y_i),
        .y_q(l1_09_single_y_q),
        .y_valid(l1_09_single_y_valid),
        .coeffs_ready(l1_09_single_coeffs_ready)
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
        .enable(parallel_chain_enable),
        .x_i(l1_08_parallel_x_i),
        .x_q(l1_08_parallel_x_q),
        .active_lanes(FullActiveLanes),
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
        .enable(parallel_chain_enable),
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
        .in_valid(parallel_output_buffer_write_valid),
        .in_ready(parallel_output_buffer_in_ready),
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
