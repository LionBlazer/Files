import sys


def update_state(bit, response, level, last_bit):
    target = 127 if bit else -128
    next_level = level + ((response * (target - level) + 128) >> 8)
    if next_level == level and level != target:
        next_level += 1 if bit else -1

    if bit == last_bit:
        response_target = 255
        delta = 7
    else:
        response_target = 0
        delta = 20

    next_response = response + ((delta * (response_target - response) + 128) >> 8)
    if next_response == response and response != response_target:
        next_response += 1 if response_target == 255 else -1

    return next_response, next_level, bit


def encode(source_path, output_path):
    response = 0
    level = 0
    last_bit = False
    packed = 0
    packed_bits = 0

    with open(source_path, "rb") as source, open(output_path, "wb") as output:
        while True:
            chunk = source.read(65536)
            if not chunk:
                break

            encoded = bytearray()
            for raw_sample in chunk:
                sample = raw_sample if raw_sample < 128 else raw_sample - 256
                bit = sample > level or (sample == level and level == 127)
                packed = (packed >> 1) + 128 if bit else packed >> 1
                response, level, last_bit = update_state(bit, response, level, last_bit)
                packed_bits += 1

                if packed_bits == 8:
                    encoded.append(packed)
                    packed = 0
                    packed_bits = 0

            output.write(encoded)

        if packed_bits:
            while packed_bits < 8:
                bit = 0 > level
                packed = (packed >> 1) + 128 if bit else packed >> 1
                response, level, last_bit = update_state(bit, response, level, last_bit)
                packed_bits += 1
            output.write(bytes((packed,)))


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("Usage: old_dfpwm.py <input.pcm8> <output.dfpwm>")
    encode(sys.argv[1], sys.argv[2])
