The artwork fixtures are synthetic test patterns with no user or third-party
artwork. The PNGs cover RGBA quadrants with a transparent quadrant, the same
pixels encoded in Adam7 passes, 16-bit white grayscale and a one-bit palette
with transparency. They use unfiltered scanlines and ordinary zlib streams;
tests compare every decoded pixel, including channel order and matte handling.
