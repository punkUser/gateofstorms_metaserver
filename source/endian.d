module endian;

import std.traits;
import std.bitmanip;
import std.conv;
import std.range;


/***
* Generate D code to do a "deep" endian swap of a structure, array or simple type.
* This is meant to be used with a mixin.
* Note that the swap is done "in place", so the variable must be mutable (make a copy if necessary).
* TODO: we can probably actually do this without a mixin and the string fun using static if...
*/
private string generate_swap_endian(T)(string var, int nesting_level = 0)
{
	static if (T.sizeof <= 1 || is(T == string))
	{
		// Single-byte types and utf-8 strings do not need byte swapping
		return "";
	}
	else static if (isIntegral!T || isSomeChar!T)
	{
		return var ~ " = swapEndian(" ~ var ~ ");\n";
	}
	// NOTE: Could alternatively use is(typeof(T[0])) here to cover anything that can be indexed...
	// That may get cause problems if this is used on some sort of complex object though (in which
	// case it is better to error out than otherwise).
	else static if (isArray!T)
	{
		// We're sort of assuming that the type of the array member is passable to swapEndian here
		// rather than doing a proper deep swap (recurse)...
		// It'll fail at compile time if this doesn't work though, so we can fix it when we need it
		// NOTE: As a minor optimization we could avoid all of this is the element type is single-byte,
		// but presumably the resulting code will be dead code eliminated if the loop ends up empty 
		// in any case.
		string loop_var = "_a" ~ to!string(nesting_level);
		string result = "foreach (ref " ~ loop_var ~ "; " ~ var ~ ") {\n";
		result ~= generate_swap_endian!(ElementType!(T))(loop_var, nesting_level + 1);
		result ~= "}\n";
		return result;
	}
	else
	{
		// Try recursing in case this member is a structure in and of itself
		// If not, "allMembers" will fail at compile time
		string result = "";
		foreach (i; __traits(allMembers, T))
		{
			alias typeof(__traits(getMember, T, i)) member_type;
			string member = var ~ "." ~ i;
			result ~= generate_swap_endian!member_type(member, nesting_level);
		}
		return result;
	}
}

public Unqual!T big_endian_to_native(T)(ref T pi)
{
	// Explicitly strip off const, etc. from the type so we can modify it in place.
	// This could potentially be slightly improved by making swap_endian generate code
	// to write from the input to output instead, but forward substitution should take
	// care of that anyways.
	// TODO: This won't work for stuff with "nested" constness, like an array of const items.
	Unqual!T p = pi;
	version(LittleEndian)
	{
		mixin(generate_swap_endian!T("p"));
	}
	return p;
}

alias big_endian_to_native native_to_big_endian;
