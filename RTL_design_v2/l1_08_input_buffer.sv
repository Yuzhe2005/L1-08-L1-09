`default_nettype none

import base_plan_l1_08_v2_pkg::*;

module l1_08_v2_input_buffer #(
    parameter int DATA_WIDTH      = DATA_WIDTH_DEFAULT,
    parameter int PARALLEL_FACTOR = PARALLEL_FACTOR_DEFAULT,
    parameter int BUFFER_DEPTH    = INPUT_BUFFER_DEPTH_DEFAULT,
    parameter int ACTIVE_LANES_W  = (PARALLEL_FACTOR <= 1) ? 1 : $clog2(PARALLEL_FACTOR + 1),
    parameter int LEVEL_W         = $clog2(BUFFER_DEPTH + PARALLEL_FACTOR + 1)
) (
    input  logic                         clk,
    input  logic                         reset_n,
    input  logic                         clear,

    input  logic signed [DATA_WIDTH-1:0] in_i [PARALLEL_FACTOR],
    input  logic signed [DATA_WIDTH-1:0] in_q [PARALLEL_FACTOR],
    input  logic [ACTIVE_LANES_W-1:0]    in_active_lanes,
    input  logic                         in_valid,
    output logic                         in_ready,

    output logic signed [DATA_WIDTH-1:0] out_i [PARALLEL_FACTOR],
    output logic signed [DATA_WIDTH-1:0] out_q [PARALLEL_FACTOR],
    output logic [ACTIVE_LANES_W-1:0]    out_active_lanes,
    output logic                         out_valid,
    input  logic                         out_ready,

    output logic [LEVEL_W-1:0]           buffer_level,
    output logic                         overflow_error,
    output logic                         active_lanes_error
);
    logic signed [DATA_WIDTH-1:0] i_queue [BUFFER_DEPTH];
    logic signed [DATA_WIDTH-1:0] q_queue [BUFFER_DEPTH];

    int unsigned level_count;
    int unsigned input_count;
    int unsigned output_count;
    int unsigned pop_count;
    int unsigned retained_count;
    int unsigned available_after_pop;
    logic        pop_fire;
    logic        push_fire;

    always_comb begin
        input_count = int'(in_active_lanes);
        if (input_count > PARALLEL_FACTOR) begin
            input_count = PARALLEL_FACTOR;
        end

        if (level_count > PARALLEL_FACTOR) begin
            output_count = PARALLEL_FACTOR;
        end else begin
            output_count = level_count;
        end

        out_valid = (output_count != 0);
        pop_fire = out_valid && out_ready;
        pop_count = pop_fire ? output_count : 0;
        available_after_pop = BUFFER_DEPTH - level_count + pop_count;
        active_lanes_error = (int'(in_active_lanes) > PARALLEL_FACTOR);
        in_ready = !active_lanes_error && (input_count <= available_after_pop);
        push_fire = in_valid && in_ready && (input_count != 0);
        retained_count = level_count - pop_count;
        buffer_level = level_count;
        out_active_lanes = output_count;

        for (int lane = 0; lane < PARALLEL_FACTOR; lane++) begin
            if (lane < output_count) begin
                out_i[lane] = i_queue[lane];
                out_q[lane] = q_queue[lane];
            end else begin
                out_i[lane] = '0;
                out_q[lane] = '0;
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n || clear) begin
            for (int idx = 0; idx < BUFFER_DEPTH; idx++) begin
                i_queue[idx] <= '0;
                q_queue[idx] <= '0;
            end
            level_count    <= 0;
            overflow_error <= 1'b0;
        end else begin
            if (in_valid && !in_ready) begin
                overflow_error <= 1'b1;
            end

            for (int idx = 0; idx < BUFFER_DEPTH; idx++) begin
                if (idx < retained_count) begin
                    i_queue[idx] <= i_queue[idx + pop_count];
                    q_queue[idx] <= q_queue[idx + pop_count];
                end else if (push_fire && (idx < (retained_count + input_count))) begin
                    i_queue[idx] <= in_i[idx - retained_count];
                    q_queue[idx] <= in_q[idx - retained_count];
                end else begin
                    i_queue[idx] <= '0;
                    q_queue[idx] <= '0;
                end
            end

            if (push_fire) begin
                level_count <= retained_count + input_count;
            end else begin
                level_count <= retained_count;
            end
        end
    end
endmodule

`default_nettype wire
