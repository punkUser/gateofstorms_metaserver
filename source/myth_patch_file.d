module myth_patch_file;

import std.mmfile;

// This isn't part of the metaserver per se, just a convenient place to put the code.
// Turns a plugin file into a patch file by modifying the header bits.
// This is useful for making metaserver patch files from plugins generated from Fear.

void make_myth_metaserver_plugin(string file_name)
{
	auto file = new MmFile(file_name, MmFile.Mode.readWrite, 0UL, null);
	file[0] = 0;
	file[1] = 7;
	file[2] = 0;
	file[3] = 0;
}
