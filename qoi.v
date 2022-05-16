module qoi

import arrays

const (
	magic_bytes      = [u8(0x71), u8(0x6f), u8(0x69), u8(0x66)]
	qoi_pixels_max   = u32(400000000)
	qoi_op_diff_tag  = u8(0x40)
	qoi_op_luma_tag  = u8(0x80)
	qoi_op_run_tag   = u8(0xC0)
	qoi_op_index_tag = u8(0x00)
	qoi_op_rgb_tag   = u8(0xFE)
	qoi_op_rgba_tag  = u8(0xFF)
	qoi_mask         = u8(0xC0)
	qoi_header_size  = 14 // 4 + 4 + 4 + 1 + 1
	qoi_end_markers  = [u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(1)]
)

struct RGBA {
	r u8
	g u8
	b u8
	a u8
}

[inline]
fn qoi_color_hash(pixel RGBA) int {
	return (pixel.r * 3 + pixel.g * 5 + pixel.b * 7 + pixel.a * 11) % 64
}

pub fn qoi_encode(raw_pixels []u8, width u32, height u32, channels u8, colorspace u8) ?[]u8 {
	if height * width >= qoi_pixels_max {
		error('Image has too many pixels to safely process.')
	}
	if height * width * colorspace != raw_pixels.len {
		error('Invalid image dimensions. Expected ${height * width * colorspace} bytes, got $raw_pixels bytes.')
	}
	if channels < 3 || channels > 4 {
		error('Invalid number of channels. Expected 3 or 4, got ${channels}.')
	}
	if colorspace > 1 {
		error('Invalid colorspace. Expected 0 (sRGB with linear alpha) or 1 (all channels linear). Got ${colorspace}.')
	}

	// need to define separately to avoid segfault https://github.com/vlang/v/issues/14416
	rgba_mapper := fn [channels] (pixel []u8) RGBA {
		// create a new pixel, if RGBA, return exact, if RGB, set a to 255 (opaque)
		return RGBA{
			r: pixel[0]
			g: pixel[1]
			b: pixel[2]
			a: if channels == 4 { pixel[3] } else { 255 }
		}
	}
	pixels := arrays.chunk(raw_pixels, channels).map(rgba_mapper)

	mut bytes := magic_bytes.clone()

	// Add width as 4 bytes
	for i in 0 .. 4 {
		bytes << u8(width >> (8 * (3 - i)))
	}
	// Add height as 4 bytes
	for i in 0 .. 4 {
		bytes << u8(height >> (8 * (3 - i)))
	}
	bytes << u8(channels)
	bytes << u8(colorspace)

	mut index := [64]RGBA{init: 0}
	mut run := u8(0)
	mut last_pixel := RGBA{
		r: 0
		g: 0
		b: 0
		a: 255
	}

	for i, pixel in pixels {
		if pixel == last_pixel {
			run++
			if run == 62 || i == pixels.len {
				bytes << qoi_op_run_tag | run - 1
				run = 0
			}
		} else {
			if run > 0 {
				bytes << qoi_op_run_tag | run - 1
				run = 0
			}

			index_pos := qoi_color_hash(pixel)

			if index[index_pos] == pixel {
				bytes << qoi_op_index_tag | u8(index_pos)
			} else if pixel.a != last_pixel.a {
				bytes << qoi_op_rgba_tag
				bytes << pixel.r
				bytes << pixel.g
				bytes << pixel.b
				bytes << pixel.a
			} else {
				vr := i8(pixel.r - last_pixel.r)
				vg := i8(pixel.g - last_pixel.g)
				vb := i8(pixel.b - last_pixel.b)

				vg_r := vr - vg
				vg_b := vb - vg

				if vr > -3 && vr < 2 && vg > -3 && vg < 2 && vb > -3 && vb < 2 {
					bytes << qoi_op_diff_tag | u8((vr + 2) << 4) | u8((vg + 2) << 2) | u8(vb + 2)
				} else if vg_r > -9 && vg_r < 8 && vg > -33 && vg < 32 && vg_b > -9 && vg_b < 8 {
					bytes << qoi_op_luma_tag | u8(vg + 32)
					bytes << u8((vg_r + 8) << 4) | u8((vg_b + 8))
				} else {
					bytes << qoi_op_rgb_tag
					bytes << pixel.r
					bytes << pixel.g
					bytes << pixel.b
				}
			}
		}

		last_pixel = pixel
	}

	for i in qoi_end_markers {
		bytes << i
	}

	return bytes
}

pub fn qoi_decode(raw_bytes []u8) ?([]u8, u32, u32, u8, u8) {
	// QOI error checking
	if raw_bytes.len < qoi_header_size + qoi_end_markers.len {
		error('Not enough raw bytes to be a qoi image. A qoi image has at minimum ${qoi_header_size + qoi_end_markers.len} bytes.')
	}

	if magic_bytes != raw_bytes[0..4] {
		error('Not a qoi image. Expected magic bytes: ${magic_bytes}. Got: ${raw_bytes[0..4]}')
	}

	read_u32_folder := fn (acc u32, elem u8) u32 {
		return u32(acc << 8) | u32(elem)
	}

	width := arrays.fold(raw_bytes[4..8], 0, read_u32_folder)
	height := arrays.fold(raw_bytes[8..12], 0, read_u32_folder)

	channels := raw_bytes[12]
	colorspace := raw_bytes[13]

	if width == 0 || height == 0 {
		error('Invalid qoi image dimensions. Image dimensions are ${width}x$height')
	}
	if channels < 3 || channels > 4 {
		error('Invalid number of channels. Got $channels, expected 3 or 4.')
	}
	if colorspace > 1 {
		error('Invalid colorspace. Got $colorspace, expected 0 or 1.')
	}
	if width * height >= qoi_pixels_max {
		error('Invalid qoi image dimensions. Image dimensions are ${width}x${height}. This is more total pixels than 
		the maximum number of pixels ($qoi_pixels_max pixels).')
	}

	qoi_pixels := raw_bytes[qoi_header_size..(raw_bytes.len - qoi_end_markers.len)]
	mut pixels := []u8{cap: int(width * height * channels)}
	mut index := [64]RGBA{}
	mut pixel := RGBA{
		r: 0
		g: 0
		b: 0
		a: 255
	}
	mut iter := 0
	mut run := 0

	for pixels.len < width * height * channels {
		if run > 0 {
			run--
		} else if iter < qoi_pixels.len {
			byte1 := qoi_pixels[iter]

			if byte1 == qoi_op_rgb_tag {
				pixel = RGBA{
					r: qoi_pixels[iter]
					g: qoi_pixels[iter + 1]
					b: qoi_pixels[iter + 2]
				}
				iter += 3
			} else if byte1 == qoi_op_rgba_tag {
				pixel = RGBA{
					r: qoi_pixels[iter]
					g: qoi_pixels[iter + 1]
					b: qoi_pixels[iter + 2]
					a: qoi_pixels[iter + 3]
				}
				iter += 4
			} else if (byte1 & qoi_mask) == qoi_op_index_tag {
				pixel = index[byte1]
			} else if (byte1 & qoi_mask) == qoi_op_diff_tag {
				pixel = RGBA{
					r: ((byte1 >> 4) & 0x03) - 2
					g: ((byte1 >> 2) & 0x03) - 2
					b: (byte1 & 0x03) - 2
				}
			} else if (byte1 & qoi_mask) == qoi_op_luma_tag {
				byte2 := qoi_pixels[iter]
				iter++
				vg := (byte1 & 0x3f) - 32

				pixel = RGBA{
					r: pixel.r + vg - 8 + ((byte2 >> 4) & 0x0f)
					g: pixel.g + vg
					b: pixel.b + vg - 8 + (byte2 & 0x0f)
				}
			} else if (byte1 & qoi_mask) == qoi_op_run_tag {
				run = int(byte1 & 0x3f)
			}

			index[qoi_color_hash(pixel)] = pixel
		}

		pixels << pixel.r
		pixels << pixel.g
		pixels << pixel.b
		if channels == 4 {
			pixels << pixel.a
		}
		println('Len: $pixels.len\tCap: $pixels.cap')
	}

	return pixels, width, height, channels, colorspace
}
