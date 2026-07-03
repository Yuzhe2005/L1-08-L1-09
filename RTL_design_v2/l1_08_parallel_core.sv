`default_nettype none

import base_plan_l1_08_v2_pkg::*;

module l1_08_v2_core_parallel #(
    parameter int TAP_NUM          = TAP_NUM_DEFAULT,
    parameter int DATA_WIDTH       = DATA_WIDTH_DEFAULT,
    parameter int COEFF_WIDTH      = COEFF_WIDTH_DEFAULT,
    parameter int COEFF_FRAC_BITS  = COEFF_FRAC_BITS_DEFAULT,
    parameter int ACCUM_WIDTH      = ACCUM_WIDTH_DEFAULT,
    parameter int MAC_LATENCY      = MAC_LATENCY_DEFAULT,
    parameter int PARALLEL_FACTOR  = PARALLEL_FACTOR_DEFAULT,
    parameter int ACTIVE_LANES_W   = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1)
) (
    input  logic                              clk,
    input  logic                              reset_n,
    input  logic                              clear,
    input  logic                              enable,
    input  logic signed [DATA_WIDTH-1:0]      x_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0]      x_q [PARALLEL_FACTOR],
    input  logic [ACTIVE_LANES_W-1:0]         active_lanes,
    input  logic                              in_valid,
    output logic                              input_ready,
    output logic signed [DATA_WIDTH-1:0]      y_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0]      y_q [PARALLEL_FACTOR],
    output logic [PARALLEL_FACTOR-1:0]        y_valid,
    output logic                              coeffs_ready,
    output logic                              active_lanes_error
);
    localparam int OUTPUT_LATENCY     = MAC_LATENCY + 1;

    localparam logic [ACTIVE_LANES_W-1:0]    ParallelFactorActive = PARALLEL_FACTOR;

    logic signed [DATA_WIDTH-1:0]  i_history [TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  q_history [TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  i_lane_window [PARALLEL_FACTOR][TAP_NUM];
    logic signed [DATA_WIDTH-1:0]  q_lane_window [PARALLEL_FACTOR][TAP_NUM];
    logic signed [COEFF_WIDTH-1:0] coeff [TAP_NUM];
    logic signed [ACCUM_WIDTH-1:0] mac_i [PARALLEL_FACTOR];
    logic signed [ACCUM_WIDTH-1:0] mac_q [PARALLEL_FACTOR];
    logic [OUTPUT_LATENCY-1:0]     lane_valid_pipe [PARALLEL_FACTOR];
    logic [PARALLEL_FACTOR-1:0]    lane_valid_in;
    logic [PARALLEL_FACTOR-1:0]    lane_out_valid;
    logic [PARALLEL_FACTOR-1:0]    lane_active;
    logic                          run_valid;
    logic [ACTIVE_LANES_W-1:0]     active_lane_count_next;

    always_comb begin
        active_lane_count_next = active_lanes;
        if (active_lane_count_next > ParallelFactorActive) begin
            active_lane_count_next = ParallelFactorActive;
        end
    end

    assign active_lanes_error = (int'(active_lanes) > PARALLEL_FACTOR);
    assign input_ready = enable && coeffs_ready && !clear && !active_lanes_error;
    assign run_valid = in_valid
                     && input_ready
                     && (active_lane_count_next != 0);

    // Bundle order is chronological: lane 0 is oldest, lane active_lanes-1 is newest.
    l1_08_v2_coeff_bank #(
        .TAP_NUM(TAP_NUM),
        .COEFF_WIDTH(COEFF_WIDTH)
    ) u_coeff_bank (
        .clk(clk),
        .reset_n(reset_n),
        .coeffs_ready(coeffs_ready),
        .coeff(coeff)
    );

    genvar lane_idx;
    genvar tap_idx;
    generate
        for (lane_idx = 0; lane_idx < PARALLEL_FACTOR; lane_idx++) begin : gen_parallel_lanes
            assign lane_active[lane_idx] = (active_lane_count_next > lane_idx);
            assign lane_valid_in[lane_idx] = run_valid
                                           && lane_active[lane_idx];
            assign lane_out_valid[lane_idx] = lane_valid_pipe[lane_idx][OUTPUT_LATENCY-1];

            for (tap_idx = 0; tap_idx < TAP_NUM; tap_idx++) begin : gen_lane_windows
                if (tap_idx <= lane_idx) begin : gen_current_bundle_sample
                    assign i_lane_window[lane_idx][tap_idx] = x_i[lane_idx - tap_idx];
                    assign q_lane_window[lane_idx][tap_idx] = x_q[lane_idx - tap_idx];
                end else begin : gen_history_sample
                    assign i_lane_window[lane_idx][tap_idx] = i_history[tap_idx - lane_idx - 1];
                    assign q_lane_window[lane_idx][tap_idx] = q_history[tap_idx - lane_idx - 1];
                end
            end

            l1_08_v2_fir_mac #(
                .TAP_NUM(TAP_NUM),
                .DATA_W(DATA_WIDTH),
                .COEFF_W(COEFF_WIDTH),
                .ACC_W(ACCUM_WIDTH)
            ) u_mac_i (
                .clk(clk),
                .reset_n(reset_n),
                .enable(enable),
                .sample_window(i_lane_window[lane_idx]),
                .coeff(coeff),
                .mac_out(mac_i[lane_idx])
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
                .sample_window(q_lane_window[lane_idx]),
                .coeff(coeff),
                .mac_out(mac_q[lane_idx])
            );
        end
    endgenerate

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
                i_history[idx] <= '0;
                q_history[idx] <= '0;
            end
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                lane_valid_pipe[lane] <= '0;
                y_i[lane]             <= '0;
                y_q[lane]             <= '0;
                y_valid[lane]         <= 1'b0;
            end
        end else if (enable) begin
            // MAC pipelines and valid pipelines advance together when the path is enabled.
            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                lane_valid_pipe[lane] <= {lane_valid_pipe[lane][OUTPUT_LATENCY-2:0],
                                          lane_valid_in[lane]};
            end

            if (run_valid) begin
                for (int idx = 0; idx < TAP_NUM; idx++) begin
                    if (idx < active_lane_count_next) begin
                        i_history[idx] <= x_i[active_lane_count_next - 1 - idx];
                        q_history[idx] <= x_q[active_lane_count_next - 1 - idx];
                    end else begin
                        i_history[idx] <= i_history[idx - active_lane_count_next];
                        q_history[idx] <= q_history[idx - active_lane_count_next];
                    end
                end

            end

            for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
                if (lane_out_valid[lane]) begin
                    y_i[lane]     <= round_sat_q15(mac_i[lane]);
                    y_q[lane]     <= round_sat_q15(mac_q[lane]);
                    y_valid[lane] <= 1'b1;
                end else begin
                    y_i[lane]     <= '0;
                    y_q[lane]     <= '0;
                    y_valid[lane] <= 1'b0;
                end
            end
        end
    end
endmodule

`default_nettype wire
