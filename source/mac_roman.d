module mac_roman;

import std.utf;
import std.conv;
import std.stdio;
import std.exception; // assumeUnique

dchar[256] generate_mac_to_dchar()
{
	// Construct translation table for extended ascii
	dchar[256] table = [
		128 : '\u00C4',
		129 : '\u00C5',

		130 : '\u00C7',
		131 : '\u00C9',
		132 : '\u00D1',
		133 : '\u00D6',
		134 : '\u00DC',
		135 : '\u00E1',
		136 : '\u00E0',
		137 : '\u00E2',
		138 : '\u00E4',
		139 : '\u00E3',

		140 : '\u00E5',
		141 : '\u00E7',
		142 : '\u00E9',
		143 : '\u00E8',
		144 : '\u00EA',
		145 : '\u00EB',
		146 : '\u00ED',
		147 : '\u00EC',
		148 : '\u00EE',
		149 : '\u00EF',

		150 : '\u00F1',
		151 : '\u00F3',
		152 : '\u00F2',
		153 : '\u00F4',
		154 : '\u00F6',
		155 : '\u00F5',
		156 : '\u00FA',
		157 : '\u00F9',
		158 : '\u00FB',
		159 : '\u00FC',

		160 : '\u2020',
		161 : '\u00B0',
		162 : '\u00A2',
		163 : '\u00A3',
		164 : '\u00A7',
		165 : '\u2022',
		166 : '\u00B6',
		167 : '\u00DF',
		168 : '\u00AE',
		169 : '\u00A9',

		170 : '\u2122',
		171 : '\u00B4',
		172 : '\u00A8',
		173 : '\u2260',
		174 : '\u00C6',
		175 : '\u00D8',
		176 : '\u221E',
		177 : '\u00B1',
		178 : '\u2264',
		179 : '\u2265',

		180 : '\u00A5',
		181 : '\u00B5',
		182 : '\u2202',
		183 : '\u2211',
		184 : '\u220F',
		185 : '\u03C0',
		186 : '\u222B',
		187 : '\u00AA',
		188 : '\u00BA',
		189 : '\u03A9',

		190 : '\u00E6',
		191 : '\u00F8',
		192 : '\u00BF',
		193 : '\u00A1',
		194 : '\u00AC',
		195 : '\u221A',
		196 : '\u0192',
		197 : '\u2248',
		198 : '\u2206',
		199 : '\u00AB',

		200 : '\u00BB',
		201 : '\u2026',
		202 : '\u00A0',
		203 : '\u00C0',
		204 : '\u00C3',
		205 : '\u00D5',
		206 : '\u0152',
		207 : '\u0153',
		208 : '\u2013',
		209 : '\u2014',

		210 : '\u2010',
		211 : '\u201D',
		212 : '\u2018',
		213 : '\u2019',
		214 : '\u00F7',
		215 : '\u25CA',
		216 : '\u00FF',
		217 : '\u0178',
		218 : '\u2044',
		219 : '\u20AC',

		220 : '\u2039',
		221 : '\u203A',
		222 : '\uFB01',
		223 : '\uFB02',
		224 : '\u2021',
		225 : '\u00B7',
		226 : '\u201A',
		227 : '\u201E',
		228 : '\u2030',
		229 : '\u00C2',

		230 : '\u00CA',
		231 : '\u00C1',
		232 : '\u00CB',
		233 : '\u00C8',
		234 : '\u00CD',
		235 : '\u00CE',
		236 : '\u00CF',
		237 : '\u00CC',
		238 : '\u00D3',
		239 : '\u00D4',

		240 : '\uF8FF',
		241 : '\u00D2',
		242 : '\u00DA',
		243 : '\u00DB',
		244 : '\u00D9',
		245 : '\u0131',
		246 : '\u02C6',
		247 : '\u02DC',
		248 : '\u00AF',
		249 : '\u02D8',

		250 : '\u02D9',
		251 : '\u02DA',
		252 : '\u00B8',
		253 : '\u02DD',
		254 : '\u02DB',
		255 : '\u02C7',
	];

	// Add the trivial ASCII mappings
	foreach (ubyte i; 1 .. 128)
		table[i] = cast(dchar)i;

	return table;
}


// From http://en.wikipedia.org/wiki/Mac_Roman
private immutable dchar[256] mac_to_dchar = generate_mac_to_dchar();
private immutable ubyte[dchar] dchar_to_mac;

shared static this()
{
	// Create the reverse mapping
	ubyte[dchar] reverse;
	foreach (i, d; mac_to_dchar)
		reverse[d] = cast(ubyte)i;
	reverse.rehash;

	dchar_to_mac = assumeUnique(reverse);
}

// Convert potentially null-terminated Mac Roman (extended ASCII) C-string to UTF8 string
// Returns the number of characters consumed from the input. Note that if special characters
// are present this will *not* be the same as the byte length of the UTF8-encoded output string!
public string mac_roman_to_string(in ubyte[] s, out size_t input_length)
{
	dchar[] result = new dchar[s.length];
	foreach (i, c; s)
	{
		if (c == 0)
		{
			result.length = i;
			input_length = i;
			break;
		}
		else
		{
			assert(c < mac_to_dchar.length);
			result[i] = mac_to_dchar[c];
		}
	}

	return toUTF8(result);
}

public string mac_roman_to_string(in ubyte[] s)
{
	size_t input_length;
	return mac_roman_to_string(s, input_length);
}

private static @nogc ubyte dchar_to_mac_default(dchar c, ubyte invalid_replacement_char = '?')
{
    auto r = (c in dchar_to_mac);
    return (r is null) ? invalid_replacement_char : *r;
}

// Convert UTF8 string to Mac Roman (extended ASCII) characters
// Not all UTF characters will map to Mac Roman; unmappable characters are replaced with
// the "invalid_replacement_char".
public ubyte[] string_to_mac_roman(in char[] s, ubyte invalid_replacement_char = '?')
{
	auto result = new ubyte[s.length + 1];
	uint length = 0;
	foreach (i, dchar c; s)
		result[length++] = dchar_to_mac_default(c, invalid_replacement_char);
	result[length++] = 0; // null terminate
	return result[0 .. length];
}

public @nogc void set_roman_array(uint N)(ref ubyte[N] text, in char[] s, ubyte invalid_replacement_char = '?')
{
	// Assume the array was already .init to 0, so we don't need to explicitly null terminate.
	foreach(i, dchar c; s)
	{
		if (i == N - 1) break;
		text[i] = dchar_to_mac_default(c, invalid_replacement_char);
	}
}