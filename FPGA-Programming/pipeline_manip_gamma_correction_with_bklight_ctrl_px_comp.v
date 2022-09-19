`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Company: 		UdS
// Engineer: 		Peter Jose
// 
// Create Date:    	09:40:34 09/16/2022 
// Design Name: 	pipeline manipulation gamma correction with backlight control pixel compensation
// Module Name:    	pipeline_manip_gamma_correction_with_bklight_ctrl_px_comp 
// Project Name: 	Displays
// Target Devices: 	Artix7
// Tool versions: 	ISE P.68d
// Description: 	Does the pipeline manipulation based on the switch configurations
//						sw[1] : selects if manipulation is needed
//						sw[0] : if sw[1] is active then this can be used to select
//								pixel compensation feature
//
// Dependencies: 	HDMI_IO_Interface, pwm_generator, seven_segment_display, ROM, 
//					unsigned_div, unsigned_mult_pipe
//
// Revision: 
// Revision 0.01 - File Created
// Additional Comments: 
//
//////////////////////////////////////////////////////////////////////////////////
module pipeline_manip_gamma_correction_with_bklight_ctrl_px_comp(
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
	 output pwm_signal,
	 
	 //seven segment
	 output [6:0] kat,
	 output [3:0] an
);

// Divider and Multiplier
wire [19:0]divider_out;
wire [9:0]remainder;
wire [19:0]dividend = 1'd1<<19;
reg [9:0]divisor; 
wire done_div;
reg en_div;

wire [29:0] r_multiplier_out,g_multiplier_out,b_multiplier_out; 
reg [19:0] div_to_mult;
reg [9:0] r_gamma_out_to_mult,g_gamma_out_to_mult,b_gamma_out_to_mult;

reg vsync_from_decoder_out_previous;
reg [9:0] r_max, g_max, b_max;
reg [13:0] disp_number = 0;
reg flag = 1;
reg sync_signal;

reg [7:0] r_from_decoder_out,g_from_decoder_out,b_from_decoder_out;
reg [7:0] r_encode_pass, g_encode_pass, b_encode_pass; 
wire [7:0] r_from_inverse_gamma_out,g_from_inverse_gamma_out,b_from_inverse_gamma_out;
wire [9:0] r_from_gamma,g_from_gamma,b_from_gamma;
reg [9:0] r_to_inverse_gamma,g_to_inverse_gamma,b_to_inverse_gamma;

reg [12:0] de_from_decoder_out,vsync_from_decoder_out,hsync_from_decoder_out;

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
wire de_to_encoder = de_from_decoder_out[12];
wire vsync_to_encoder = vsync_from_decoder_out[12];
wire hsync_to_encoder = hsync_from_decoder_out[12]; 


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

wire [9:0] max_value = r_max>g_max? (r_max>b_max?r_max:b_max):(g_max>b_max?g_max:b_max);

// Initial begin block
initial begin
	r_max = 0;
	g_max = 0;
	b_max = 0;
	disp_number = 14'd0;
end

// always block
always @(posedge p_clock_from_decoder)
begin
	if (vsync_from_decoder == 1 && vsync_from_decoder_out_previous == 0)
	begin
		// store the max value for displaying the content
		disp_number[9:0] <= max_value ;
		pwm_value <= max_value;
		divisor <= max_value;
		en_div <= 1;
		flag <= 1;
		sync_signal <=1;
	end
	else
	begin
		if (flag == 1)
		begin
			// reset the max values of the channels
			r_max <= 0;
			g_max <= 0;
			b_max <= 0;	
			flag <= 0; 
			sync_signal <=0;
			en_div <= 0;
		end
		else
		begin
			// check for max value when the de signal is high
			if(de_from_decoder)
			begin
				// channel selection output based on the selected channel
				r_max <= r_from_gamma>r_max ? r_from_gamma: r_max;
				g_max <= g_from_gamma>g_max ? g_from_gamma: g_max;
				b_max <= b_from_gamma>b_max ? b_from_gamma: b_max;
			end
		end
	end
	
	// to control the gamma adjustments
	if(sw[1])
	begin
		// RGB decoder to reg
		r_from_decoder_out <= r_from_decoder;
		g_from_decoder_out <= g_from_decoder;
		b_from_decoder_out <= b_from_decoder;
		
		// to control the compensation
		if(sw[0])
		begin
			// divider out is given to multiplication
			div_to_mult <= divider_out;

			// gamma value to provider to the multiplier
			r_gamma_out_to_mult <= r_from_gamma;
			g_gamma_out_to_mult <= g_from_gamma;
			b_gamma_out_to_mult <= b_from_gamma;

			// inverse gamma from the multiplier output
			r_to_inverse_gamma <= r_multiplier_out[18:9];
			g_to_inverse_gamma <= g_multiplier_out[18:9];
			b_to_inverse_gamma <= b_multiplier_out[18:9];

			// compensate for delays in the multiplication and division
			de_from_decoder_out[12:0] <= {de_from_decoder_out[11:0],de_from_decoder}; 
			vsync_from_decoder_out[12:0] <= {vsync_from_decoder_out[11:0],vsync_from_decoder};
			hsync_from_decoder_out[12:0] <= {hsync_from_decoder_out[11:0],hsync_from_decoder};
		end
		else
		begin
			r_to_inverse_gamma <= r_from_gamma;
			g_to_inverse_gamma <= g_from_gamma;
			b_to_inverse_gamma <= b_from_gamma;

			// compensate for delays in the multiplication and division
			de_from_decoder_out[12] <= de_from_decoder; 
			vsync_from_decoder_out[12] <= vsync_from_decoder;
			hsync_from_decoder_out[12] <= hsync_from_decoder;
		end
		r_encode_pass <= r_from_inverse_gamma_out;
		g_encode_pass <= g_from_inverse_gamma_out; 
		b_encode_pass <= b_from_inverse_gamma_out;
	end
	else
	begin
		// bypass the manipulation
		r_encode_pass <= r_from_decoder;
		g_encode_pass <= g_from_decoder;
		b_encode_pass <= b_from_decoder;
		pwm_value <= 1023;
		de_from_decoder_out[12] <= de_from_decoder; 
		vsync_from_decoder_out[12] <= vsync_from_decoder;
		hsync_from_decoder_out[12] <= hsync_from_decoder;
	end

	// store the previous vsync with current value
	vsync_from_decoder_out_previous <= vsync_from_decoder;
end

// divider
unsigned_div#(.N(20),.M(10)) divide (
	.quotient(divider_out), 
	.remainder(remainder), 
	.done(done_div), 
	.dividend(dividend), 
	.divisor(divisor), 
	.clk(p_clock_from_decoder), 
	.en(en_div)
);

// multiplier
unsigned_mult_pipe#(.M(20),.N(10)) mulitplier_r(
	.res(r_multiplier_out), 
	.clk(p_clock_from_decoder), 
	.a(div_to_mult), 
	.b(r_gamma_out_to_mult)
);

// multiplier
unsigned_mult_pipe#(.M(20),.N(10)) mulitplier_g(
	.res(g_multiplier_out), 
	.clk(p_clock_from_decoder), 
	.a(div_to_mult), 
	.b(g_gamma_out_to_mult)
);

// multiplier
unsigned_mult_pipe#(.M(20),.N(10)) mulitplier_b(
	.res(b_multiplier_out), 
	.clk(p_clock_from_decoder), 
	.a(div_to_mult), 
	.b(b_gamma_out_to_mult)
);


// RED
ROM #(.ROM_PATH(R_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) r_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(r_from_decoder_out) ,
	.dout	(r_from_gamma)
);

ROM #(.ROM_PATH(R_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) r_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(r_to_inverse_gamma) ,
	.dout	(r_from_inverse_gamma_out)
);

// GREEN
ROM #(.ROM_PATH(G_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) g_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(g_from_decoder_out) ,
	.dout	(g_from_gamma)
);

ROM #(.ROM_PATH(G_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) g_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(g_to_inverse_gamma) ,
	.dout	(g_from_inverse_gamma_out)
);

// BLUE
ROM #(.ROM_PATH(B_GAMMA_COE_PATH),
	.DATA_WIDTH(10) ,
	.ADDR_WIDTH(8) ,
	.LAST_ADDR(255)) b_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(b_from_decoder_out) ,
	.dout	(b_from_gamma)
);

ROM #(.ROM_PATH(B_INVERSE_GAMMA_COE_PATH),
	.DATA_WIDTH(8) ,
	.ADDR_WIDTH(10) ,
	.LAST_ADDR(1023)) b_inverse_gamma (
	.clk	(p_clock_from_decoder),
	.addr	(b_to_inverse_gamma) ,
	.dout	(b_from_inverse_gamma_out)
);


// Seven segment module
seven_segment_display seven_segment_disp(
	.clk(refclkin_100),
	.number(disp_number),
	.seg(kat),
	.an(an)
);
 
// PWM generator module
pwm_generator pwm_gen (
	.clk(refclkin_100), 
	.reset(reset_PWM), 
	.sync_signal(sync_signal), 
	.pwm_value(pwm_value), 
	.t_lsb(t_lsb), 
	.pwm_signal(pwm_signal)
);

// HDMI input output
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