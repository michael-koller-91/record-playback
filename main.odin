package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import ma "vendor:miniaudio"

NUM_CHANNELS :: 2
SAMPLE_RATE :: 44100

UserData :: struct {
	ring_buffer: ^ma.pcm_rb,
}

log_callback :: proc "c" (user_data: rawptr, level: u32, message: cstring) {
	context = runtime.default_context()
	fmt.println(message)
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

	key: [1]byte
	result: ma.result

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
	ring_buffer: ma.pcm_rb
	result = ma.pcm_rb_init(
		.f32,
		NUM_CHANNELS,
		capture_period_frames * 40 * 10,
		nil,
		nil,
		&ring_buffer,
	)
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

	ma.log_register_callback(
		ma.device_get_log(&capture_device),
		ma.log_callback_init(log_callback, nil),
	)

	result = ma.device_start(&capture_device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to start capture_device:", result)
		os.exit(1)
	}
	log.debug("Started capture_device")

	fmt.print("Press Enter to stop capture...")
	os.read(os.stdin, key[:])

	ma.device_stop(&capture_device)
	log.debug("Stopped capture_device")

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

	ma.log_register_callback(
		ma.device_get_log(&playback_device),
		ma.log_callback_init(log_callback, nil),
	)

	result = ma.device_start(&playback_device)
	if result != .SUCCESS {
		fmt.eprintln("Failed to start playback_device:", result)
		os.exit(1)
	}
	log.debug("Started playback_device")

	fmt.print("Press Enter to stop playback...")
	os.read(os.stdin, key[:])

	ma.device_stop(&playback_device)
	log.debug("Stopped playback_device")
}
