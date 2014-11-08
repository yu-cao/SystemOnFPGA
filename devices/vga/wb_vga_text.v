`include "define.vh"


/**
 * VGA text mode with wishbone connection interfaces and inner buffer.
 * Author: Zhao, Hongyu  <power_zhy@foxmail.com>
 */
module wb_vga_text (
	input wire clk,  // main clock
	input wire rst,  // synchronous reset
	input wire vga_clk,  // VGA clock generated by VGA core
	input wire [H_COUNT_WIDTH-1:0] h_count_core,  // horizontal sync count from VGA core
	input wire [H_COUNT_WIDTH-1:0] h_disp_max,  // maximum display range for horizontal
	input wire [V_COUNT_WIDTH-1:0] v_count_core,  // vertical sync count from VGA core
	input wire [V_COUNT_WIDTH-1:0] v_disp_max,  // maximum display range for vertical
	input wire h_sync_core,  // horizontal sync from VGA core
	input wire v_sync_core,  // vertical sync from VGA core
	input wire h_en_core,  // scan line inside horizontal display range from VGA core
	input wire v_en_core,  // scan line inside vertical display range from VGA core
	input wire [ASCII_H_WIDTH-1:0] cursor_h_pos,  // cursor's horizontal position
	input wire [ASCII_V_WIDTH-1:0] cursor_v_pos,  // cursor's vertical position
	input wire cursor_en,  // cursor display enable
	input wire cursor_refresh,  // refresh cursor when it moves
	input wire [15:0] cursor_timer,  // cursor's flash time in ms
	input wire [31:16] vram_base,  // base address for VRAM
	// VGA interfaces
	output reg h_sync,
	output reg v_sync,
	output reg r, g, b,
	// wishbone master interfaces
	input wire wbm_clk_i,
	output reg wbm_cyc_o,
	output reg wbm_stb_o,
	output reg [31:2] wbm_addr_o,
	output reg [2:0] wbm_cti_o,
	output reg [1:0] wbm_bte_o,
	output reg [3:0] wbm_sel_o,
	output reg wbm_we_o,
	input wire [31:0] wbm_data_i,
	output reg [31:0] wbm_data_o,
	input wire wbm_ack_i
	);
	
	`include "function.vh"
	`include "vga_define.vh"
	parameter
		CLK_FREQ = 100;  // main clock frequency in MHz
	localparam
		CLK_COUNT = CLK_FREQ * 1000,
		CLK_COUNT_WIDTH = GET_WIDTH(CLK_COUNT-1);
	
	// delay core signals 2 clock, 1 for fetching ASCII data and the other for fetching font pixels
	reg [H_COUNT_WIDTH-1:0] h_count_d1, h_count_d2;
	reg [V_COUNT_WIDTH-1:0] v_count_d1, v_count_d2;
	reg h_sync_d1, h_sync_d2;
	reg v_sync_d1, v_sync_d2;
	reg h_en_d1, h_en_d2;
	reg v_en_d1, v_en_d2;
	
	always @(posedge vga_clk) begin
		if (rst) begin
			h_count_d1 <= 0;
			h_count_d2 <= 0;
			v_count_d1 <= 0;
			v_count_d2 <= 0;
			h_sync_d1 <= 0;
			h_sync_d2 <= 0;
			v_sync_d1 <= 0;
			v_sync_d2 <= 0;
			h_en_d1 <= 0;
			h_en_d2 <= 0;
			v_en_d1 <= 0;
			v_en_d2 <= 0;
		end
		else begin
			h_count_d1 <= h_count_core;
			h_count_d2 <= h_count_d1;
			v_count_d1 <= v_count_core;
			v_count_d2 <= v_count_d1;
			h_sync_d1 <= h_sync_core;
			h_sync_d2 <= h_sync_d1;
			v_sync_d1 <= v_sync_core;
			v_sync_d2 <= v_sync_d1;
			h_en_d1 <= h_en_core;
			h_en_d2 <= h_en_d1;
			v_en_d1 <= v_en_core;
			v_en_d2 <= v_en_d1;
		end
	end
	
	// buffer
	reg h_en_prev, v_en_prev;
	reg [ASCII_H_WIDTH-2:0] buf_addr_w = 0;
	reg line_switch;
	wire [31:0] buf_data_r;
	wire [15:0] ascii_data;
	reg [15:0] ascii_data_d1;
	
	buffer_2l #(
		.DATA_BITS(32),  // one data containing two characters
		.ADDR_BITS(ASCII_H_WIDTH-1)
		) BUFFER (
		.clk(wbm_clk_i),
		.switch(line_switch),
		.clk_w(wbm_clk_i),
		.en_w(wbm_ack_i),
		.addr_w(buf_addr_w),
		.data_w(wbm_data_i),
		.clk_r(vga_clk),
		.addr_r(h_count_core[H_COUNT_WIDTH-1:FONT_H_WIDTH+1]),
		.data_r(buf_data_r)
	);
	
	assign
		ascii_data = h_count_d1[FONT_H_WIDTH] ? buf_data_r[31:16] : buf_data_r[15:0];
	always @(posedge vga_clk) begin
		if (rst) begin
			ascii_data_d1 <= 0;
		end
		else begin
			ascii_data_d1 <= ascii_data;
		end
	end
	
	always @(*) begin
		wbm_we_o <= 0;
		wbm_sel_o <= 4'b1111;
		wbm_data_o <= 0;
		wbm_addr_o[31:16] <= vram_base;
	end
	
	always @(posedge wbm_clk_i) begin
		if (rst) begin
			h_en_prev <= 0;
			v_en_prev <= 0;
		end
		else begin
			h_en_prev <= h_en_d2;
			v_en_prev <= v_en_d2;
		end
	end
	
	// data transmission control
	wire wb_line_last, vga_line_done, vga_frame_done;
	assign
		wb_line_last = buf_addr_w == h_disp_max>>(FONT_H_WIDTH+1),
		vga_line_done = v_en_prev && h_en_prev && ~h_en_d2 && (v_count_d2[FONT_V_WIDTH-1:0] == {FONT_V_WIDTH{1'b1}}),
		vga_frame_done = v_en_prev && h_en_prev && ~h_en_d2 && (v_count_d2 == v_disp_max);
	
	localparam
		S_IDLE = 0,
		S_FIRST = 1,
		S_FOLLOW = 2,
		S_WAIT = 3;
	
	reg [1:0] state = 0;
	reg [1:0] next_state;
	
	always @(*) begin
		line_switch = 0;
		next_state = 0;
		case (state)
			S_IDLE: begin
				next_state = S_FIRST;
			end
			S_FIRST: begin
				if (wb_line_last && wbm_ack_i) begin
					line_switch = 1;
					next_state = S_FOLLOW;
				end
				else begin
					next_state = S_FIRST;
				end
			end
			S_FOLLOW: begin
				if (wb_line_last && wbm_ack_i) begin
					next_state = S_WAIT;
				end
				else begin
					next_state = S_FOLLOW;
				end
			end
			S_WAIT: begin
				if (vga_frame_done) begin
					line_switch = 1;
					next_state = S_FIRST;
				end
				else if (vga_line_done) begin
					line_switch = 1;
					next_state = S_FOLLOW;
				end
				else begin
					next_state = S_WAIT;
				end
			end
		endcase
	end
	
	always @(posedge wbm_clk_i) begin
		if (rst)
			state <= 0;
		else
			state <= next_state;
	end
	
	always @(posedge wbm_clk_i) begin
		if (rst || line_switch)
			buf_addr_w <= 0;
		else if (wbm_cyc_o && wbm_ack_i)
			buf_addr_w <= buf_addr_w + 1'h1;
	end
	
	always @(posedge wbm_clk_i) begin
		if (rst || vga_frame_done)
			wbm_addr_o[15:2] <= 0;
		else if (wbm_cyc_o && wbm_ack_i)
			wbm_addr_o[15:2] <= wbm_addr_o[15:2] + 1'h1;
	end
	
	always @(posedge wbm_clk_i) begin
		wbm_cyc_o <= 0;
		wbm_stb_o <= 0;
		wbm_cti_o <= 0;
		wbm_bte_o <= 0;
		if (~rst) case (next_state)
			S_FIRST: begin
				wbm_cyc_o <= 1;
				wbm_stb_o <= 1;
				wbm_cti_o <= 3'b010;  // incrementing burst
				wbm_bte_o <= 2'b00;  // linear burst
			end
			S_FOLLOW: begin
				wbm_cyc_o <= 1;
				wbm_stb_o <= 1;
				if (~wb_line_last) begin
					wbm_cti_o <= 3'b010;  // incrementing burst
					wbm_bte_o <= 2'b00;  // linear burst
				end
				else begin
					wbm_cti_o <= 3'b111;  // end of burst
					wbm_bte_o <= 0;
				end
			end
		endcase
	end
	
	// font
	reg [FONT_H-1:0] font_data;
	wire font_r, font_g, font_b;
	
	reg [FONT_H-1:0] font_memory [0:FONT_V*128-1];
	initial begin
		$readmemh("font.txt", font_memory);
	end
	
	always @(posedge vga_clk) begin
		font_data <= ascii_data[7] ? {FONT_H{1'b1}} : font_memory[{ascii_data[6:0], v_count_d1[FONT_V_WIDTH-1:0]}];
	end
	
	assign
		font_r = font_data[FONT_H-1-h_count_d2[FONT_H_WIDTH-1:0]] ? ascii_data_d1[10] : ascii_data_d1[14],
		font_g = font_data[FONT_H-1-h_count_d2[FONT_H_WIDTH-1:0]] ? ascii_data_d1[9] : ascii_data_d1[13],
		font_b = font_data[FONT_H-1-h_count_d2[FONT_H_WIDTH-1:0]] ? ascii_data_d1[8] : ascii_data_d1[12];
	
	// cursor
	reg [ASCII_H_WIDTH-1:0] cursor_h_prev;
	reg [ASCII_V_WIDTH-1:0] cursor_v_prev;
	reg [15:0] cursor_timer_prev;
	wire cursor_move, cursor_timer_change;
	
	reg [CLK_COUNT_WIDTH-1:0] clk_count = 0;
	reg [15:0] ms_count = 0;
	reg cursor_light = 0;
	
	always @(posedge clk) begin
		if (rst) begin
			cursor_h_prev <= 0;
			cursor_v_prev <= 0;
			cursor_timer_prev <= 0;
		end
		else begin
			cursor_h_prev <= cursor_h_pos;
			cursor_v_prev <= cursor_v_pos;
			cursor_timer_prev <= cursor_timer;
		end
	end
	
	assign
		cursor_move = (cursor_h_prev != cursor_h_pos) | (cursor_v_prev != cursor_v_pos),
		cursor_timer_change = (cursor_timer_prev != cursor_timer);
	
	always @(posedge clk) begin
		if (rst || ~cursor_en) begin
			clk_count <= 0;
			ms_count <= 0;
			cursor_light <= 0;
		end
		else if ((cursor_refresh && cursor_move) || cursor_timer_change || (cursor_timer == 0)) begin
			clk_count <= 0;
			ms_count <= 0;
			cursor_light <= 1;
		end
		else begin
			if (clk_count == CLK_COUNT-1) begin
				clk_count <= 0;
				if (ms_count == cursor_timer) begin
					ms_count <= 0;
					cursor_light <= ~cursor_light;
				end
				else begin
					ms_count <= ms_count + 1'h1;
				end
			end
			else begin
				clk_count <= clk_count + 1'h1;
			end
		end
	end
	
	always @(posedge vga_clk) begin
		if (rst) begin
			h_sync <= 0;
			v_sync <= 0;
			r <= 0;
			g <= 0;
			b <= 0;
		end
		else begin
			h_sync <= h_sync_d2;
			v_sync <= v_sync_d2;
			if (h_en_d2 && v_en_d2) begin
				if (cursor_light && (h_count_d2[H_COUNT_WIDTH-1:FONT_H_WIDTH] == cursor_h_pos) && (v_count_d2[V_COUNT_WIDTH-1:FONT_V_WIDTH] == cursor_v_pos)) begin
					r <= ~font_r;
					g <= ~font_g;
					b <= ~font_b;
				end
				else begin
					r <= font_r;
					g <= font_g;
					b <= font_b;
				end
			end
			else begin
				r <= 0;
				g <= 0;
				b <= 0;
			end
		end
	end
	
endmodule