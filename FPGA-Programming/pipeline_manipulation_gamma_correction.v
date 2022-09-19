`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 		UdS
// Engineer: 		Peter Jose
// 
// Create Date:     15:53:13 09/15/2022 
// Design Name: 	Gamma correction
// Module Name:    	pipeline_manipulation_gamma_correction 
// Project Name: 	Displays
// Target Devices:  Artix7
// Tool versions: 	
// Description: 	manipulate the image pipeline for gamma correction
//
// Dependencies: 	HDMI_IO_Interface, pwm_generator, seven_segment_display
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module pipeline_manipulation_gamma_correction(
    input refclkin_100, // 100 MHz
    output reg hdmi_rx_txen = 1'b1,
    output reg hdmi_hpd = 1'b1,
    output [7:0]led,
    input reset, // reset DVI decoder
    input [7:0] sw,
    input BTN_U, // reset PLL/MMCM (sysclock)
    
    // HDMI in
    input TMDS_IN_clk_p,
    input TMDS_IN_clk_n,
    input [2:0] TMDS_IN_data_n,
    input [2:0] TMDS_IN_data_p,
	 inout edid_sda_io,
	 input edid_scl_in,
	
    //	HDMI out
    output TMDS_OUT_clk_p,
    output TMDS_OUT_clk_n,
    output [2:0] TMDS_OUT_data_p,
    output [2:0] TMDS_OUT_data_n,
	 
	 // PWM
	 input reset_PWM,
	 input sync_signal,
	 output pwm_signal,
	 
	 //seven segment
	 output [6:0] kat,
	 output [3:0] an
);

reg [7:0] r_from_decoder_out,g_from_decoder_out,b_from_decoder_out;
reg [7:0] r_encode_pass, g_encode_pass, b_encode_pass; 
wire [7:0] r_from_inverse_gamma_out,g_from_inverse_gamma_out,b_from_inverse_gamma_out;
wire [9:0] r_from_gamma_inter,g_from_gamma_inter,b_from_gamma_inter;

reg de_from_decoder_out,vsync_from_decoder_out,hsync_from_decoder_out;

// internal signals
wire [7:0] r_from_decoder,g_from_decoder,b_from_decoder;
wire de_from_decoder,vsync_from_decoder,hsync_from_decoder;
wire p_clock_from_decoder;
wire MMCM_refclk_locked;
wire p_clock_from_decoder_locked;

// connect input to output of IO-Blackbox 
wire [7:0] r_to_encoder = r_encode_pass;
wire [7:0] g_to_encoder = g_encode_pass; 
wire [7:0] b_to_encoder = b_encode_pass;
wire de_to_encoder = de_from_decoder_out;
wire vsync_to_encoder = vsync_from_decoder;
wire hsync_to_encoder = hsync_from_decoder; 


// debug LEDs
assign led[0] = MMCM_refclk_locked;
assign led[1] = de_from_decoder;
assign led[2] = vsync_from_decoder;
assign led[3] = hsync_from_decoder;
assign led[4] = p_clock_from_decoder_locked;
assign led[5] = r_from_decoder > 1 ? 1 : 0;
assign led[6] = g_from_decoder > 1 ? 1 : 0;
assign led[7] = b_from_decoder > 1 ? 1 : 0;

// for pwm
reg [11:0] t_lsb = 12'd407;				// 12'd1629 for 60 Hz, 12'd407 for 240 Hz
reg [9:0] pwm_value = ~0;

// for gamma correction
parameter R_GAMMA_COE_PATH = "gamma.coe";
parameter G_GAMMA_COE_PATH = "gamma.coe";
parameter B_GAMMA_COE_PATH = "gamma.coe";

parameter R_INVERSE_GAMMA_COE_PATH = "inverse_gamma.coe";
parameter G_INVERSE_GAMMA_COE_PATH = "inverse_gamma.coe";
parameter B_INVERSE_GAMMA_COE_PATH = "inverse_gamma.coe";

// always block
always @(posedge p_clock_from_decoder)
begin
	if (sync_signal)
		pwm_value[9:6] <= sw[7:4];
	if(sw[3])
	begin
		 r_from_decoder_out <= r_from_decoder;
		 g_from_decoder_out <= g_from_decoder;
		 b_from_decoder_out <= b_from_decoder;
		 r_encode_pass <= r_from_inverse_gamma_out;
		 g_encode_pass <= g_from_inverse_gamma_out; 
		 b_encode_pass <= b_from_inverse_gamma_out;
	end
	else
	begin
		r_encode_pass <= r_from_decoder;
		g_encode_pass <= g_from_decoder;
		b_encode_pass <= b_from_decoder;
	end
	de_from_decoder_out <= de_from_decoder;
	vsync_from_decoder_out <= vsync_from_decoder;
	hsync_from_decoder_out <= hsync_from_decoder;
end

// RED
ROM #(.ROM_PATH(R_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) r_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(r_from_decoder_out) ,
	.dout	(r_from_gamma_inter)
);

ROM #(.ROM_PATH(R_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) r_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(r_from_gamma_inter) ,
	.dout	(r_from_inverse_gamma_out)
);

// GREEN
ROM #(.ROM_PATH(G_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) g_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(g_from_decoder_out) ,
	.dout	(g_from_gamma_inter)
);

ROM #(.ROM_PATH(G_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) g_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(g_from_gamma_inter) ,
	.dout	(g_from_inverse_gamma_out)
);

// BLUE
ROM #(.ROM_PATH(B_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) b_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(b_from_decoder_out) ,
	.dout	(b_from_gamma_inter)
);

ROM #(.ROM_PATH(B_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) b_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(b_from_gamma_inter) ,
	.dout	(b_from_inverse_gamma_out)
);


// Instantiate Seven segment module
seven_segment_display seven_segment_disp(
	.clk(refclkin_100),
	.number(disp_number),
	.seg(kat),
	.an(an)
);
 
// Instantiate PWM generator module
pwm_generator pwm_gen (
	.clk(refclkin_100), 
	.reset(reset_PWM), 
	.sync_signal(sync_signal), 
	.pwm_value(pwm_value), 
	.t_lsb(t_lsb), 
	.pwm_signal(pwm_signal)
);

// Instantiate HDMI input output
HDMI_IO_Interface HDMI_IO_Interface_internal (
    .refclk(refclkin_100), 
    .TMDS_IN_data_p_n({TMDS_IN_data_p,TMDS_IN_data_n}), 
    .TMDS_IN_clk_p_n({TMDS_IN_clk_p,TMDS_IN_clk_n}), 
    .edid_sda_io(edid_sda_io), 
    .edid_scl_in(edid_scl_in), 
	 
    .TMDS_OUT_clk_p_n({TMDS_OUT_clk_p,TMDS_OUT_clk_n}), 
    .TMDS_OUT_data_p_n({TMDS_OUT_data_p,TMDS_OUT_data_n}), 
    .reset_pll(BTN_U), 
    .reset_encoder_decoder(reset), 
	 
    .sync_signals_from_decoder({de_from_decoder,vsync_from_decoder,hsync_from_decoder}), 
    .RGB_from_decoder({r_from_decoder,g_from_decoder,b_from_decoder}), 
    .sync_signals_to_encoder({de_to_encoder,vsync_to_encoder,hsync_to_encoder}), 
    .RGB_to_encoder({r_to_encoder,g_to_encoder,b_to_encoder}), 
	 .p_clock_from_decoder(p_clock_from_decoder),
	 
    .refclock_locked(MMCM_refclk_locked), 
    .pclock_locked(p_clock_from_decoder_locked)
    );

endmodule
