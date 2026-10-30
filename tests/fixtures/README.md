# FLAC fixtures

These files are deterministic, synthetic audio generated for gain's decoder
tests. The `.s32le` files are FFmpeg reference decodes used for exact sample
comparison. The encoded fixtures cover 16-bit and 24-bit samples, mono,
independent and decorrelated stereo, constant and noisy input, wasted bits,
and a 24-bit/192 kHz stream with 16,384-sample blocks.

They contain no recorded or copyrighted audio.
