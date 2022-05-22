module qoi

import arrays

// i am smol brain programmer, but [direct_array_access] may be useful, need to see how to do the bounds checking

const (
	magic_bytes    = 'qoif'.bytes()
	max_pixels     = u32(400000000)
	op_diff_tag    = u8(0b01_000000)
	op_luma_tag    = u8(0b10_000000)
	op_run_tag     = u8(0b11_000000)
	op_index_tag   = u8(0b00_000000)
	op_rgb_tag     = u8(0b1111_1110)
	op_rgba_tag    = u8(0b1111_1111)
	mask_2         = u8(0b11_000000)
	max_run_length = 62
	header_size    = 14 // 4 + 4 + 4 + 1 + 1
	end_markers    = '\0\0\0\0\0\0\0\1'.bytes() //[u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(0), u8(1)]
	index_size     = 64
)

[inline]
fn qoi_color_hash(r u8, g u8, b u8, a u8) int {
	return (r * 3 + g * 5 + b * 7 + a * 11) % qoi.index_size
}

[inline]
fn u32_to_bytes(num u32) []u8 {
	return []u8{len: 4, init: u8(num >> (8 * (3 - it)))}
}

[inline]
fn bytes_to_u32(num []u8) ?u32 {
	if num.len != 4 {
		gt_or_lt := if num.len > 4 { 'greater' } else { 'less' }
		error('Number of bytes in array is $gt_or_lt than 4. u32 is exactly 4 bytes long.')
	}

	return u32(num[0]) << 24 | u32(num[1]) << 16 | u32(num[2]) << 8 | u32(num[3])
}

pub fn encode(pixels []u8, width int | u32, height int | u32, nr_channels int | u8) ?[]u8 {
	w := match width {
		int { u32(width) }
		u32 { width }
	}
	h := match height {
		int { u32(height) }
		u32 { height }
	}
	c := match nr_channels {
		int { u8(nr_channels) }
		u8 { nr_channels }
	}

	if w * h > qoi.max_pixels {
		error('Image is too large to safely encode in QOI format.')
	}

	mut qoi_image := qoi.magic_bytes.clone()
	qoi_image << u32_to_bytes(w)
	qoi_image << u32_to_bytes(h)
	qoi_image << c
	qoi_image << u8(0) // srgb with linear alpha

	// TODO: Test with 64*4 size, use / and % to get values
	// TODO: Test with 64 u32
	mut index := [qoi.index_size][]u8{}
	mut last_pixel := [u8(0), u8(0), u8(0), u8(255)]
	mut run := 0

	for i, pixel in arrays.chunk(pixels, int(c)) {
		alpha := if pixel.len == 4 { pixel[3] } else { u8(255) }
		if pixel == last_pixel {
			run++
			if run == qoi.max_run_length || i == pixels.len / c {
				qoi_image << qoi.op_run_tag | u8(run - 1)
				run = 0
			}
		} else {
			if run > 0 {
				qoi_image << qoi.op_run_tag | u8(run - 1)
				run = 0
			}

			idx := qoi_color_hash(pixel[0], pixel[1], pixel[2], alpha)
			if index[idx] == pixel {
				qoi_image << qoi.op_index_tag | u8(idx)
			} else if alpha != last_pixel[3] {
				qoi_image << [qoi.op_rgba_tag, pixel[0], pixel[1], pixel[2], alpha]
			} else {
				vr := i8(pixel[0] - last_pixel[0])
				vg := i8(pixel[1] - last_pixel[1])
				vb := i8(pixel[2] - last_pixel[2])

				vg_r := vr - vg
				vg_b := vb - vg

				if vr > -3 && vr < 2 && vg > -3 && vg < 2 && vb > -3 && vb < 2 {
					qoi_image << qoi.op_diff_tag | (u8(vr + 2) << 4) | (u8(vg + 2) << 2) | u8(vb + 2)
				} else if vg_r > -9 && vg_r < 8 && vg > -33 && vg < 32 && vg_b > -9 && vg_b < 8 {
					qoi_image << [qoi.op_luma_tag | u8(vg + 32), (u8(vg_r + 8) << 4) | u8(vg_b + 8)]
				} else {
					qoi_image << [qoi.op_rgb_tag, pixel[0], pixel[1], pixel[2]]
				}
			}
		}

		last_pixel = [pixel[0], pixel[1], pixel[2], alpha]
	}

	qoi_image << qoi.end_markers

	return qoi_image
}

pub fn decode(data []u8) ?([]u8, u32, u32, int, int) {
	if data.len < qoi.header_size + qoi.end_markers.len {
		error('Insufficient data. Bytes provided are less than the minimum number of bytes for a qoi file.')
	}

	if data[0..4] != qoi.magic_bytes {
		error('Missing qoi magic bytes. Got ${data[0..3].bytestr()} instead of ${qoi.magic_bytes.bytestr()}.')
	}

	w := bytes_to_u32(data[4..8]) or { panic('Unable to read 4 bytes for width from data.') }
	h := bytes_to_u32(data[8..12]) or { panic('Unable to read 4 bytes for width from data.') }

	if w == 0 || h == 0 || w * h >= qoi.max_pixels {
		error('Image defines invalid size. Given ${w}x${h}.')
	}

	c := int(data[12])

	if c !in [3, 4] {
		error('Invalid no. of channels. QOI only supports RGB(3 channel) and RGBA (4 channel). Given $c instead.')
	}

	cs := int(data[13])
	if cs !in [0, 1] {
		error('Invalid colorspace. QOI only supports sRGB with linear alpha (0) and all channels linear (1). Given $cs instead.')
	}

	// data#[-8..] == starting from last - 8 to last
	end_markers_exist := data#[-8..] == qoi.end_markers
	if !end_markers_exist {
		eprintln('Missing end markers. Got ${data#[-8..]} The data may be incomplete, or the end markers may be invalid.')
	}

	mut index := [qoi.index_size][4]u8{}
	mut run := 0
	mut pixel := [4]u8{}
	pixel[0] = 0
	pixel[1] = 0
	pixel[2] = 0
	pixel[3] = 255
	
	// quick test with 100k bytes shows cap is slightly faster (1-3 ms) than len+init when
	// writing (arr[i] = vs arr << ). maybe some checks for = slows down? for smaller files
	// preallocating takes significantly longer than setting cap
	mut pixels := []u8{cap: int(w * h) * c}

	// skip header & end markers if they exist
	// slices are allocate on grow, so shouldn't have too much perf impact
	qoi_data := if end_markers_exist { data#[..-8][14..] } else { data[14..] }

	mut i := 0
	for count := 0; count < int(w * h); count++ {
		if run > 0 {
			run--
		} else if i < qoi_data.len {
			byte1 := qoi_data[i]

			match byte1 {
				qoi.op_rgb_tag {
					pixel[0] = qoi_data[i + 1]
					pixel[1] = qoi_data[i + 2]
					pixel[2] = qoi_data[i + 3]
					i += 3
				}
				qoi.op_rgba_tag {
					pixel[0] = qoi_data[i + 1]
					pixel[1] = qoi_data[i + 2]
					pixel[2] = qoi_data[i + 3]
					pixel[3] = qoi_data[i + 4]
					i += 4
				}
				else {
					match byte1 & qoi.mask_2 {
						qoi.op_index_tag {
							pixel = index[byte1]
						}
						qoi.op_diff_tag {
							pixel[0] += ((byte1 >> 4) & 0x03) - 2
							pixel[1] += ((byte1 >> 2) & 0x03) - 2
							pixel[2] += (byte1 & 0x03) - 2
						}
						qoi.op_luma_tag {
							byte2 := qoi_data[i + 1]

							vg := (byte1 & ~qoi.mask_2) - 32

							pixel[0] += vg - 8 + ((byte2 >> 4) & 0x0f)
							pixel[1] += vg
							pixel[2] += vg - 8 + (byte2 & 0x0f)

							i += 1
						}
						qoi.op_run_tag {
							run = int(byte1 & ~qoi.mask_2)
						}
						else {
							panic('Reached ${@LINE} of ${@FN} in ${@MOD}. This should not be possible.') // impossible point
						}
					}
				}
			}
			index[qoi_color_hash(pixel[0], pixel[1], pixel[2], pixel[3])] = pixel
			i += 1
		}
		pixels << pixel[0]
		pixels << pixel[1]
		pixels << pixel[2]
		pixels << pixel[3]
	}
	return pixels, w, h, c, cs
}
