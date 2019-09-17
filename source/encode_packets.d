module encode_packets;

import exceptions;

import std.bitmanip;
import core.stdc.string;
import std.socket;
import std.exception;
import std.random;

// These values match the ones used by the client and thus cannot be changed
// without breaking compatibility.
private immutable key_size_in_bytes = 8;
private immutable ushort prime = 32717;
private immutable ushort generator = 18334;
private immutable ubyte[8] packetCheck1 = [23, 34, 232, 45, 34, 53, 28, 214];
private immutable ubyte[8] packetCheck2 = [40, 92, 34, 234, 4,  82, 8, 42];

static assert(prime < 32768, "Prime modulus must fit in 16-bit uint");
static assert(generator < prime);

public alias ubyte[key_size_in_bytes] key_type;

private pure nothrow int power_mod(int base, int exponent)
{
	int result = base;
	foreach (i; 1..exponent)
		result = (result * base) % prime;
	return result;
}

public pure nothrow void generate_session_key(
	const key_type public_key,
	const key_type private_key,
	out key_type session_key)
{
	for (int i = 0; i < key_type.length; i += 2)
	{
		ubyte[2] pub = public_key[i .. i+2];
		ubyte[2] priv = private_key[i .. i+2];
		short k = cast(ushort)power_mod(
			littleEndianToNative!ushort(pub),
			littleEndianToNative!ushort(priv));
		session_key[i .. i+2] = nativeToLittleEndian(k)[];
	}
}

// Non-pure since it generates a random key and thus affects the RNG state
public void generate_public_key(out key_type public_key, out key_type private_key)
{
	for (int i = 0; i < key_type.length; i += 2)
	{
		int private_key_i = std.random.uniform(0, prime);
		int public_key_i = power_mod(generator, private_key_i);
		private_key[i .. i+2] = nativeToLittleEndian(cast(ushort)private_key_i)[];
		public_key[i .. i+2] = nativeToLittleEndian(cast(ushort)public_key_i)[];
	}
}

// Modifies the data pointed to by the input slice... duplicate before calling if necessary
public @nogc ubyte[] decrypt(ubyte[] data, const key_type session_key)
{
	// Undo pass 2
	foreach (i, ref d; data)
		d = d ^ session_key[i % key_type.length];

	// Undo pass 1
	// NOTE: Removed the "iteration" outer loop here since it is set to 1 iteration
	// in the shipping code, and it would be broken for small packets and more than 1
	// iteration anyways...

	// This seems kinda made up ("security through obscurity?"), but that's what
	// the original encoding code effectively does...
	int data_length = cast(int)data.length;
	for (int index = 0; index < data_length; ++index)
	{
		// NOTE: Um... this seems broken for data_length < 3
		// Luckily our check arrays are longer than that, but still ugly.
		data[(index + data_length - 3) % data_length] ^= data[index];
		data[index] ^= data[(index + data_length - 1) % data_length];
	}
	for (int index = data_length - 1; index >= 0; --index)
	{
		data[(index + 2) % data_length] ^= data[index];
		data[index] ^= data[(index + 1) % data_length];
	}

	// Trim nonsense ints
	data = data[int.sizeof .. $ - int.sizeof];

	// Compare check arrays
	if (data[0 .. packetCheck1.sizeof] != packetCheck1 || data[$ - packetCheck2.sizeof .. $] != packetCheck2)
    {
        // nogc: preallocate exception; not 100% sure this is legit but given our use case here
        // where this will always propogate and crash the fiber, and shouldn't actually ever really
        // occur in any regular use with the standard Myth client, acceptable for now.
        // Could also just return something back up to the caller and let them throw an exception
        // as needed once we get out of nogc code...
        static const e = new ClientProtocolException("Packet check bits do not match");
        throw e;
    }

	// Trim off check arrays
	data = data[packetCheck1.sizeof .. $ - packetCheck2.sizeof];

	return data;
}

// NOTE: Output array must be 24 bytes longer than input (check bytes + random bytes)
public @nogc void encrypt(
    immutable(ubyte[]) input,
    const key_type session_key,
    uint random0, uint random1,
    ubyte[] output)
{
	// Make space for extra stuff
	// NOTE: We could be somewhat more efficient by having the caller put the data in
	// the right place to start with, but it's not a big deal given what we do next anyways.
	assert(output.length == (input.length + packetCheck1.sizeof + packetCheck2.sizeof + 2 * int.sizeof));

    // Endianness obviously doesn't matter for random, but convenient touint...
	output[0 .. int.sizeof] = nativeToLittleEndian(random0)[];
	output[int.sizeof .. int.sizeof + packetCheck1.sizeof] = packetCheck1[];
    output[int.sizeof + packetCheck1.sizeof .. $ - int.sizeof - packetCheck2.sizeof] = input[];
	output[$ - int.sizeof - packetCheck2.sizeof.. $ - int.sizeof] = packetCheck2[];
	output[$ - int.sizeof .. $] = nativeToLittleEndian(random1)[];

	// Pass 1 - see notes in decrypt
	int data_length = cast(int)output.length;
	for (int index = 0; index < data_length; ++index)
	{
		output[index] ^= output[(index + 1) % data_length];
		output[(index + 2) % data_length] ^= output[index];
	}
	for (int index = data_length - 1; index >= 0; --index)
	{
		output[index] ^= output[(index + data_length - 1) % data_length];
		output[(index + data_length - 3) % data_length] ^= output[index];
	}

	// Pass 2
	foreach (i, ref d; output)
		d = d ^ session_key[i % key_type.length];
}
