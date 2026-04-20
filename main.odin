package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import ma "vendor:miniaudio"
import rl "vendor:raylib"

NUM_CHANNELS :: 2
SAMPLE_RATE :: 44100

WINDOW_HEIGHT :: 100
WINDOW_WIDTH :: 400

UserData :: struct {
	ring_buffer: ^ma.pcm_rb,
}

capture_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	// context = runtime.default_context()

	data_ptr: rawptr
	user_data := cast(^UserData)device.pUserData
	ring_buffer := user_data.ring_buffer

	// capture samples and write to a ring buffer
	frames_written: u32 = 0
	for frames_written < frame_count {
		frames_to_write := frame_count - frames_written

		if frames_to_write < 0 {
			break
		}

		result := ma.pcm_rb_acquire_write(ring_buffer, &frames_to_write, &data_ptr)
		if result != .SUCCESS {
			ma.log_postf(
				ma.device_get_log(device),
				u32(ma.log_level.LOG_LEVEL_ERROR),
				"Failed to acquire capture PCM frames from ring buffer: %i",
				result,
			)
			break
		}

		if frames_to_write == 0 {
			break
		}

		// copy the data from capture buffer to ring buffer
		ma.copy_pcm_frames(data_ptr, input, u64(frames_to_write), ma.format.f32, NUM_CHANNELS)
		result = ma.pcm_rb_commit_write(ring_buffer, frames_to_write)
		if result != .SUCCESS {
			ma.log_postf(
				ma.device_get_log(device),
				u32(ma.log_level.LOG_LEVEL_ERROR),
				"Failed to commit capture PCM frames to ring buffer: %i",
				result,
			)
			break
		}

		frames_written += frames_to_write
	}
}

playback_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	data_ptr: rawptr
	user_data := cast(^UserData)device.pUserData
	ring_buffer := user_data.ring_buffer

	// read ring buffer and play back samples
	frames_read: u32 = 0
	for frames_read < frame_count {
		frames_to_read := frame_count - frames_read

		if frames_to_read < 0 {
			break
		}

		result := ma.pcm_rb_acquire_read(ring_buffer, &frames_to_read, &data_ptr)
		if result != .SUCCESS {
			ma.log_postf(
				ma.device_get_log(device),
				u32(ma.log_level.LOG_LEVEL_ERROR),
				"Failed to acquire capture PCM frames from ring buffer: %i",
				result,
			)
			break
		}

		if frames_to_read == 0 {
			break
		}

		// copy the data from ring buffer to playback buffer
		ma.copy_pcm_frames(output, data_ptr, u64(frames_to_read), ma.format.f32, NUM_CHANNELS)
		result = ma.pcm_rb_commit_read(ring_buffer, frames_to_read)
		if result != .SUCCESS {
			ma.log_postf(
				ma.device_get_log(device),
				u32(ma.log_level.LOG_LEVEL_ERROR),
				"Failed to commit capture PCM frames to ring buffer: %i",
				result,
			)
			break
		}

		frames_read += frames_to_read
	}
}

main :: proc() {
	context.logger = log.create_console_logger(.Debug)

	// context.logger = log.create_console_logger(.Fatal)
	// rl.SetTraceLogLevel(.NONE)

	key: [1]byte
	result: ma.result

	rl.InitWindow(WINDOW_WIDTH, WINDOW_HEIGHT, "Capture and Playback")
	defer rl.CloseWindow()

	/* ------------------------- capture ------------------------- */

	capture_config := ma.device_config_init(.capture)
	capture_config.dataCallback = capture_callback
	capture_config.capture.format = .f32
	capture_config.capture.channels = NUM_CHANNELS
	capture_config.sampleRate = SAMPLE_RATE

	capture_device: ma.device
	result = ma.device_init(nil, &capture_config, &capture_device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to initialize capture_device:", result)
		os.exit(1)
	}
	log.debug("Initialized capture_device")
	defer ma.device_uninit(&capture_device)
	defer log.debug("Uninitialized capture_device")

	capture_period_frames := capture_device.capture.internalPeriodSizeInFrames
	buffer_size_in_frames := capture_period_frames * 40 * 3
	ring_buffer: ma.pcm_rb
	result = ma.pcm_rb_init(.f32, NUM_CHANNELS, buffer_size_in_frames, nil, nil, &ring_buffer)
	if result != .SUCCESS {
		fmt.eprintln("Failed to initialize ring_buffer:", result)
		os.exit(1)
	}
	log.debug("Initialized ring_buffer")
	defer ma.pcm_rb_uninit(&ring_buffer)
	defer log.debug("Uninitialized ring_buffer")

	ma.pcm_rb_set_sample_rate(&ring_buffer, capture_device.sampleRate)

	user_data: UserData
	user_data.ring_buffer = &ring_buffer

	capture_device.pUserData = &user_data

	/* ------------------------- playback ------------------------- */

	playback_config := ma.device_config_init(.playback)
	playback_config.dataCallback = playback_callback
	playback_config.playback.format = .f32
	playback_config.playback.channels = NUM_CHANNELS
	playback_config.sampleRate = SAMPLE_RATE

	playback_device: ma.device
	result = ma.device_init(nil, &playback_config, &playback_device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to initialize playback_device:", result)
		os.exit(1)
	}
	log.debug("Initialized playback_device")
	defer ma.device_uninit(&playback_device)
	defer log.debug("Uninitialized playback_device")

	playback_device.pUserData = &user_data

	/* ------------------------- main loop ------------------------- */

	x_pad: i32 = WINDOW_WIDTH / 10
	y_pad: i32 = WINDOW_HEIGHT / 10

	font_size: f32 = WINDOW_HEIGHT / 6

	third_1 := (WINDOW_HEIGHT - (2 * y_pad)) / 3
	third_2 := 2 * third_1
	third_3: f32 = 3 * f32(third_1)

	capturing := false
	new_capturing_done := false
	capturing_prev := false
	playing_back := false
	start_playback := false

	first_capturing_happened := false

	for !rl.WindowShouldClose() {
		capturing_prev = capturing
		new_capturing_done = false

		if rl.IsKeyPressed(.SPACE) {
			first_capturing_happened = true
			capturing = true
			result = ma.device_start(&capture_device)
			if result != .SUCCESS {
				fmt.eprintln("Failed to start capture_device:", result)
				os.exit(1)
			}
		}
		if rl.IsKeyReleased(.SPACE) {
			capturing = false
			new_capturing_done = true
			result = ma.device_stop(&capture_device)
			if result != .SUCCESS {
				fmt.eprintln("Failed to stop capture_device:", result)
				os.exit(1)
			}
		}

		if new_capturing_done {
			result = ma.device_start(&playback_device)
			if result != .SUCCESS {
				fmt.eprintln("Failed to start playback_device:", result)
				os.exit(1)
			}
			playing_back = true
		}

		available_write: f32 = 0.0
		if playing_back {
			available_write =
				f32(ma.pcm_rb_available_write(&ring_buffer)) / f32(buffer_size_in_frames)

			if available_write >= 1.0 {
				playing_back = false
				result = ma.device_stop(&playback_device)
				if result != .SUCCESS {
					fmt.eprintln("Failed to stop playback_device:", result)
					os.exit(1)
				}
			}
		}

		// don't capture and play back at the same time
		if (capturing & playing_back) {
			capturing = false
		}

		available_read: f32 = 0.0
		if (capturing) {
			available_read =
				f32(ma.pcm_rb_available_read(&ring_buffer)) / f32(buffer_size_in_frames)
		}

		startPos, endPos: rl.Vector2
		line_start_x := f32(x_pad) + font_size + font_size
		line_end_x := WINDOW_WIDTH - f32(x_pad)
		rl.BeginDrawing()
		{
			rl.ClearBackground(rl.BLACK)

			rl.DrawText(
				"Press [ESC] to exit",
				x_pad,
				third_1 - i32(font_size / 2),
				i32(font_size),
				rl.WHITE,
			)
			rl.DrawText(
				"Hold [SPACE] to record",
				x_pad,
				third_2 - i32(font_size / 2),
				i32(font_size),
				rl.WHITE,
			)

			// TODO: stop recording if available_read == 1
			// TODO: replay with green progress marker until red recording marker

			// progress bar line
			startPos[0], startPos[1] = line_start_x, third_3
			endPos[0], endPos[1] = line_end_x, third_3
			rl.DrawLineV(startPos, endPos, rl.BLUE)

			if capturing {
				radius: f32 = font_size / 2
				rl.DrawCircle(x_pad + i32(radius), i32(third_3), radius, rl.RED)

				startPos[0], startPos[1] =
					line_start_x +
					available_read * (line_end_x - line_start_x),
					third_3 +
					font_size / 2
				endPos[0], endPos[1] =
					line_start_x +
					available_read * (line_end_x - line_start_x),
					third_3 -
					font_size / 2
				rl.DrawLineV(startPos, endPos, rl.RED)
			}

			if playing_back {
				v1, v2, v3: rl.Vector2
				v1[0], v1[1] = f32(x_pad), third_3 + font_size / 2
				v2[0], v2[1] = f32(x_pad) + font_size, third_3
				v3[0], v3[1] = f32(x_pad), third_3 - font_size / 2
				rl.DrawTriangle(v1, v2, v3, rl.GREEN)

				startPos[0], startPos[1] =
					line_start_x +
					available_write * available_read * (line_end_x - line_start_x),
					third_3 +
					font_size / 2
				endPos[0], endPos[1] =
					line_start_x +
					available_write * available_read * (line_end_x - line_start_x),
					third_3 -
					font_size / 2
				rl.DrawLineV(startPos, endPos, rl.GREEN)
			}
		}
		rl.EndDrawing()
	}
}
