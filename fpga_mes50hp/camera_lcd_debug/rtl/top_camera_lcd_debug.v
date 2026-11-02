`timescale 1ns/1ps

module top_camera_lcd_debug (
    input wire clk_27m,
    input wire reset_n,
    input wire [5:0] keys_n,
    input wire uart_rxd,
    output wire uart_txd,
    output wire [7:0] led,
    output wire [4:0] lcd_r,
    output wire [5:0] lcd_g,
    output wire [4:0] lcd_b,
    output wire lcd_dclk,
    output wire lcd_hsync,
    output wire lcd_vsync,
    output wire lcd_de,
    output wire touch_sclk,
    output wire touch_cs_n,
    output wire touch_mosi,
    input wire touch_busy,
    input wire touch_miso,
    input wire touch_irq_n,
    output wire cam_scl,
    inout wire cam_sda,
    input wire cam_vsync,
    input wire [7:0] cam_data,
    output wire cam_rclk,
    output wire cam_we,
    output wire cam_oe_n,
    output wire cam_wrst_n,
    output wire cam_rrst_n
);
    reg [15:0] powerup = 0;
    reg [1:0] reset_sync = 0;
    wire reset = !(&powerup);
    always @(posedge clk_27m) begin
        reset_sync <= {reset_sync[0], reset_n};
        if (!reset_sync[1]) powerup <= 0;
        else if (!(&powerup)) powerup <= powerup + 1'b1;
    end

    wire [5:0] pressed;
    wire [5:0] press_pulse;
    wire [7:0] rx_data;
    wire rx_valid;
    wire rx_error;
    wire [7:0] tx_data;
    wire tx_start;
    wire tx_busy;
    reg camera_mode;
    reg frozen;
    reg sensor_bars;
    reg restart;
    reg report;
    reg [15:0] uart_errors;
    reg [25:0] heartbeat;
    reg [2:0] touch_first;
    reg [2:0] touch_second;
    wire configured;
    wire failed;
    wire [7:0] pid;
    wire [7:0] version;
    wire [7:0] config_step;
    wire [15:0] frame_count;
    wire [15:0] vsync_count;
    wire [15:0] timeout_count;
    wire pixel_write;
    wire [14:0] write_address;
    wire [15:0] write_data;
    wire frame_done;
    wire frame_ack;
    wire frame_valid;
    wire frame_tick;
    wire [14:0] read_address;
    wire [15:0] read_data;
    wire [3:0] capture_state;

    assign touch_sclk = 0;
    assign touch_cs_n = 1;
    assign touch_mosi = 0;
    assign led = {touch_second[2], frame_count[0], frozen, camera_mode,
                  frame_valid, failed, configured, heartbeat[24]};

    debug_keys #(.DEBOUNCE_CYCLES(540000)) keys (
        .clk(clk_27m), .reset(reset), .keys_n(keys_n), .pressed(pressed), .press_pulse(press_pulse)
    );
    debug_uart #(.CLOCK_HZ(27000000), .BAUD(115200)) uart (
        .clk(clk_27m), .reset(reset), .rxd(uart_rxd), .txd(uart_txd),
        .rx_data(rx_data), .rx_valid(rx_valid), .rx_frame_error(rx_error),
        .tx_data(tx_data), .tx_start(tx_start), .tx_busy(tx_busy)
    );

    always @(posedge clk_27m) begin
        if (reset) begin
            camera_mode <= 0;
            frozen <= 0;
            sensor_bars <= 0;
            restart <= 0;
            report <= 0;
            uart_errors <= 0;
            heartbeat <= 0;
            touch_first <= 0;
            touch_second <= 0;
        end else begin
            heartbeat <= heartbeat + 1'b1;
            touch_first <= {!touch_irq_n, touch_busy, touch_miso};
            touch_second <= touch_first;
            restart <= 0;
            report <= |press_pulse || rx_valid;
            if (rx_error) uart_errors <= uart_errors + 1'b1;
            if (press_pulse[0] || (rx_valid && rx_data == "c")) camera_mode <= 1;
            if (press_pulse[1] || (rx_valid && rx_data == "b")) camera_mode <= 0;
            if (press_pulse[2] || (rx_valid && rx_data == "f")) frozen <= !frozen;
            if (press_pulse[3] || (rx_valid && rx_data == "t")) begin
                sensor_bars <= !sensor_bars;
                restart <= 1;
                frozen <= 0;
                camera_mode <= 1;
            end
            if (press_pulse[4] || (rx_valid && rx_data == "r")) begin
                restart <= 1;
                frozen <= 0;
            end
        end
    end

    camera_config sensor_configuration (
        .clk(clk_27m), .reset(reset), .restart(restart), .sensor_bars(sensor_bars),
        .configured(configured), .failed(failed), .pid(pid), .version(version),
        .step(config_step), .scl(cam_scl), .sda(cam_sda)
    );
    camera_fifo_capture capture (
        .clk(clk_27m), .reset(reset || restart), .configured(configured), .freeze(frozen),
        .frame_ack(frame_ack), .vsync(cam_vsync), .data(cam_data),
        .rclk(cam_rclk), .we(cam_we), .oe_n(cam_oe_n),
        .wrst_n(cam_wrst_n), .rrst_n(cam_rrst_n),
        .pixel_write(pixel_write), .pixel_address(write_address), .pixel_data(write_data),
        .frame_done(frame_done), .frame_count(frame_count), .timeout_count(timeout_count),
        .vsync_count(vsync_count), .state(capture_state)
    );
    camera_framebuffer framebuffer (
        .clk(clk_27m), .reset(reset || restart || !configured),
        .pixel_write(pixel_write), .write_address(write_address), .write_data(write_data),
        .frame_done(frame_done), .frame_tick(frame_tick), .read_address(read_address),
        .read_data(read_data), .frame_valid(frame_valid), .frame_ack(frame_ack)
    );
    lcd_debug_video video (
        .clk(clk_27m), .reset(reset), .camera_mode(camera_mode), .frame_valid(frame_valid),
        .configured(configured), .failed(failed), .frozen(frozen), .pen_down(touch_second[2]),
        .image_pixel(read_data), .image_address(read_address), .frame_tick(frame_tick),
        .dclk(lcd_dclk), .hsync(lcd_hsync), .vsync(lcd_vsync), .de(lcd_de),
        .red(lcd_r), .green(lcd_g), .blue(lcd_b)
    );
    camera_console console (
        .clk(clk_27m), .reset(reset), .report(report), .camera_mode(camera_mode),
        .configured(configured), .failed(failed), .pid(pid), .version(version), .step(config_step),
        .frozen(frozen), .frames(frame_count), .vsyncs(vsync_count), .timeouts(timeout_count),
        .keys(pressed), .touch(touch_second), .uart_errors(uart_errors),
        .tx_busy(tx_busy), .tx_start(tx_start), .tx_data(tx_data)
    );
endmodule
