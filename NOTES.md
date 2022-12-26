#  A collection of notes, insights, knowledge gained, etc.

## Further reading

- HFS is defined in [the “File Manager” chapter of Inside Macintosh: Files](https://developer.apple.com/library/archive/documentation/mac/pdf/Files/File_Manager.pdf), under “Data Organization on Volumes”.
- That gets expanded upon and corrected in [TN1041, “Inside Macintosh: Files Errata”](https://developer.apple.com/library/archive/technotes/tn/tn1041.html).
- [Inside Macintosh: Text](https://developer.apple.com/library/archive/documentation/mac/pdf/Text.pdf) covers (among many other things) the encodings used by HFS (in summary: a subset of MacRoman and friends called “the Macintosh character set”, originally defined by Inside Macintosh Volume I) in chapter 5, “Text Utilities”. In particular, the definition of `RelString` is the definition of how node names are sorted in the B*-trees.
- [The “SCSI Manager” chapter of Inside Macintosh: Devices](https://developer.apple.com/library/archive/documentation/mac/pdf/Devices/SCSI_Manager.pdf) includes the definition of the Apple Partition Map. I'm not going to deal with APM here (not yet, anyway) but if you want to figure out how to find the Apple_HFS partition(s) in an APM disk, that's where to start. The contents of an Apple_HFS partition are an HFS volume.
- HFS+ is defined in [TN1150, “HFS Plus Volume Format”](https://developer.apple.com/library/archive/technotes/tn/tn1150.html).
- There are a few HFS-related Developer Q&As and technotes in [the documentation archive](https://developer.apple.com/library/archive/navigation/). In particular, [OPS08](https://developer.apple.com/library/archive/qa/ops/ops08.html) is about a bug that affects how node names are sorted in B*-trees.
- [Apple's implementation in Mac OS X](https://opensource.apple.com/source/hfs/hfs-556.60.1/core/) is open source. (The oldest version with the implementation published is [366.1.1](https://opensource.apple.com/source/hfs/hfs-366.1.1/core/); if any classic-HFS bits have been stripped out in more-recent versions, the old version may be more relevant.)

## Layout

The disk is divided into 512-byte blocks. Physical blocks start from the very start of the disk; the first physical blocks include the partition map. The first block of a volume is the first logical block.

The first two logical blocks are reserved for “boot blocks”, which include a variety of parameter settings used by classic Macs. (Very likely none of it is used by modern macOS.)

After that comes the volume header, which HFS calls the “master directory block” or MDB, or “volume information block” or VIB. (IM:F defines both but then goes on to use the former term exclusively.) The volume header identifies the volume as HFS and contains metadata such as the creation and modification dates, the volume name (in HFS only), the size and number of allocation blocks, and references to the catalog file and extents overflow file (and more, in HFS+).

Next after the volume header is the volume bitmap, a bit vector identifying which allocation blocks are in use. In HFS, the volume bitmap is always contiguous and directly after the header; in HFS+, it's allocated as a file, with its own extent record in the volume header. (It *can* still be contiguous and immediately after the header; it just doesn't have to be.)

On HFS, the volume bitmap is the last thing before the allocation blocks. This is where all file storage happens; allocation blocks are marked as used in the volume bitmap, and used for either fork contents or B*-tree node storage. The size of an allocation block is set in the volume header; in HFS, it may be 512 bytes (or larger for large volumes), while HFS+ recommends (but does not require) that allocation blocks be no less than 4 KiB. `

In HFS+, at least, allocation blocks are counted from the very start of the volume; TN1150 says that any allocation blocks containing portions of the boot blocks, volume header, alternate volume header, or 512-byte footer must be marked as in use. This means that at least the first and last allocation blocks are always marked as in-use. IM:F doesn't make super clear whether this applies to HFS, although it implies that it doesn't, as Figure 2-5 shows allocation blocks being counted from block #0 immediately after the VBM. 

The last two logical blocks of the volume are reserved for the alternate volume header (ideally a verbatim copy of the main volume header) and 512 bytes of empty space. IM:F says of the alternate volume header:

>This copy is updated only when the extents overflow file or the catalog file grows larger. This alternate [MDB] is intended for use solely by disk utilities.

TN1150 says essentially the same thing:

>The implementation should only update this copy when the length or location of one of the special files changes. The alternate volume header is intended for use solely by disk repair utilities.

TN1150 also says, regarding the last 512 bytes:

>The last 512 bytes were used during Apple's CPU manufacturing process.

## The volume bitmap

TN1150 makes a couple of important clarifications regarding the layout of the volume bitmap on disk (which HFS+ turns into the allocation bitmap file):

>Using a file allows the bitmap itself to be allocated from allocation blocks. This simplifies the design, since volumes are now comprised of only one type of block -- the allocation block. The HFS is slightly more complex because it uses 512-byte blocks to hold the allocation bitmap and allocation blocks to hold file data.

This means that the volume bitmap is always in 0x200-byte chunks, regardless of `drAlBlkSize`.

>All of the volume's structures, including the volume header, are part of one or more allocation blocks (with the possible exception of the alternate volume header, discussed below). This differs from HFS, which has several structures (including the boot blocks, master directory block, and bitmap) which are not part of any allocation block.

This part has two ramifications:

- The first allocation block on an HFS volume starts *after* the VBM. (Though, does it have to start at a position that is a multiple of the block size? That is, if the VBM's last 0x200-byte chunk ends on a multiple of 0x200 but not 0x400, does there need to be padding between that point and the next allocation-block-size multiple?)
- Including everything all the way out to the edges of the volume changes _which_ blocks have to be marked as used. Effectively, the allocation bitmap on HFS+ has a handful of new blocks, marked as used, before and after the volume contents.

Also, the allocation bitmap can't exist in the same allocation block as the volume header. For volumes with 0x200-byte blocks, this is easy enough. For volumes with larger blocks, the bitmap has to be relocated. *Everything* might have to be relocated.

“Journeyman Turbo™” has an allocation block size of 16.5 K (0x4200 bytes). If we keep that block size, 15 K of the first block has to go unused. The allocation bitmap has to go somewhere, likely (though not necessarily) in block #1. The extents overflow file in the HFS volume starts at 9728 bytes; block #2 in an HFS+ volume with the same block size wouldn't start until 33792 bytes.

If we're to try to keep things in the same places, we may have to change the block size and update the extents to match. It might make sense to try to force everything to 0x200; in “Journeyman Turbo™”'s case, this would necessitate multiplying all the extent values by 33, in addition to needing to add 2 to all the starts.

Other divisors may be possible but might complicate placing the special files. 0x4200 could be divided by 11 rather than 33 to get 0x600-byte blocks. That could be small enough to put the boot blocks (0x400) and volume header (x200) in block #0, while still potentially being able to spend EO file reduction savings on keeping the three special files together. 

## Extents

An extent is basically the same thing as an NSRange: a start point and a length. An extent is measured in allocation blocks.

An extent descriptor describes one extent, and an extent _record_ contains either three (HFS) or eight (HFS+) extent descriptors.

Fragmentation may cause files (especially large ones) to need to occupy multiple extents (the “Largest Unused Block” problem). A file's catalog entry holds one extent record; if the file ends up in more extents than will fit there, the additional extents get recorded in the extents overflow file, which is a B*-tree file (more on that in a bit).

An extent record is, essentially, a zero-terminated list. Any non-empty extents after an empty extent are ignored. (This isn't documented but it's the behavior of the Mac OS X implementation. I hadn't seen that before writing my implementation—luckily I guessed right!)

The volume header contains extent records for the catalog and extents overflow files.

**Question:** It's not clear what happens if either of these files needs a fourth/ninth extent. Presumably the catalog file can be added to the extents overflow file—but can the extents overflow file?

## B*-trees

B*-trees are the foundational data structure of the catalog and extents overflow files, as well as the extended attributes file in HFS+.

A B*-tree file is indeed a file, even though it is not in the folder hierarchy (which is recorded in the catalog). B*-tree files are stored in allocation blocks from the same pool used for regular files.

A B*-tree file contains a series of nodes. Each node starts with a node descriptor, and then has a series of records. Records are accessed by retrieving the record's starting offset from the end of the node (they are in reverse order, so the first record offset is the last two bytes of the node, the second record offset is the next two bytes above that, and so on), and the next record's starting offset in order to compute the record's length. The last record offset points to the beginning of any empty space between the end of the last record and the start of the offset stack; if there is no empty space, it points to itself.

The first node is the **header node**. The header node contains a header record, which describes the tree as a whole (total number of nodes, how many unused, that sort of thing), and a map record, which is a bit vector indicating which nodes are in use. The header node may have forward links to **map nodes**, which extend the map record if the number of nodes in the tree exceeds the capacity of the header node's map record. The header record is always the first record, and the map record is always the third record. (The second record is reserved for File Manager and is otherwise undocumented.)

Among the values in the header record is the number of the root node, which is always either an index node or a leaf node.

An **index node** is an intermediate step in the node hierarchy. Records in an index node direct searches down to either further index nodes or to leaf nodes.

A **leaf node** is a terminus of the node hierarchy. Records in a leaf node describe files and folders, and their relationship to their parent folders.

In HFS, every node is 512 bytes (IM: F). In HFS+, each B*-tree file defines its node size in the header record; the minimum size is 512 bytes, and the node size must be a power of two (TN1150). TN1150 says:

>HFS Plus uses the following default node sizes:
>
>- 4 KB (8KB in Mac OS X) for the catalog file
>- 1 KB (4KB in Mac OS X) for the extents overflow file
>- 4 KB for the attributes file
>
>These sizes are set when the volume is initialized and cannot be easily changed. It is legal to initialize an HFS Plus volume with different node sizes, but the node sizes must be large enough for an index node to contain two keys of maximum size (plus the other overhead such as a node descriptor, record offsets, and pointers to children).
>
>**IMPORTANT:**  
>The node size of the catalog file must be at least kHFSPlusCatalogMinNodeSize (4096).
>
>**IMPORTANT:**  
>The node size of the attributes file must be at least kHFSPlusAttrMinNodeSize (4096).

An HFS-style B*-tree is not *just* a tree. A tree is a directed graph from a root toward leaves. HFS-style B*-trees are trees, but each node also has links to siblings of the same height, as clarified by TN1150:

>All the nodes in a given level (whose height field is the same) must be chained via their fLink and bLink field. The node with the smallest keys must be first in the chain and its bLink field must be zero. The node with the largest keys must be last in the chain and its fLink field must be zero.

Thus, an HFS-style B*-tree has what I call “rows”:

- the header/map node row (height 0)
- index row (height n)
- ⋮
- index row (height 2)
- leaf row (height 1)

(Heights shown here are as described in TN1150; I haven't tried to nail down how heights work in HFS.)

The bottom index row, at height 2, points to a subset of the nodes on the leaf row at height 1. The row at height 3, if there is one, points to a subset of nodes on row 2.

(As noted in both sources, a B*-tree can have only one node, which would be a leaf node with no index nodes above it. It's also possible to have a B*-tree with few enough leaf nodes that one index node covers it.)

TN1150 describes how B*-tree searching works:

>When an implementation needs to find the data associated with a particular search key, it begins searching at the root node. Starting with the first record, it searches for the record with the greatest key that is less than or equal to the search key. In then moves to the child node (typically an index node) and repeats the same process.

I interpret this to mean that every row must start with the first key in the tree. Otherwise, if you're searching for that key, you wouldn't find it because the first record in the first index node you visit would have a greater key.

## Catalog records

There are four kinds of records in a catalog leaf node:

- file
- folder/directory
- file thread
- folder thread

A file or folder record describes the metadata of the item itself (e.g., its creation and modification dates, as well as Finder info such as type and creator codes). A file record also includes the extents of the file's data and resource forks.

Thread records relate a file or folder to its parent, and also give the file or folder's name. (This does mean that, on HFS+, thread records are actually larger than catalog records!)

TN1150 notes that HFS does not require a file to have a thread record, but HFS+ does.

## The myth of the “catalog node ID”

IM:F, TN1150, and hfs_format.h all call the item numbers borne by every file and folder in the catalog “catalog node IDs” or CNIDs. This unfortunately overloads the term “node”, also used in the context of pages in a B*-tree—particularly unfortunate given that the catalog *is* a B*-tree.

CNIDs are not B*-tree node numbers. They are item numbers, orthogonal to the numbering of B*-tree nodes from the logical start of the B*-tree file. (Node 0 is the header node, node 1 is at least traditionally the root node, and all else is anarchy.)

Really, they ought to be called “Catalog Item Numbers” or something. Something that doesn't use the word “node”.

## Comparing names the HFS way

HFS does not use Unicode; it uses an 8-bit encoding vaguely resembling (if not exactly) MacRoman. Comparisons are case-insensitive.

On Classic Mac OS, File Manager uses `RelString`, an API in the Text Utilities, for comparisons. This API is long gone from the macOS headers as of Xcode 13.3. (There's also `EqualString`, which is similarly gone, and is only for testing equality according to HFS rules and not relative comparison.)

Inside Macintosh: Text defines `RelString`'s comparison rules in table 5-2, and the preceding page 5-16:

- “Since the Macintosh character set only contains characters with codes from $0 to $D8, the file system comparison rules only work correctly for character codes through $D8.”
	- Chapter 1 defines “the Standard Roman Character Set”—which we now call MacRoman—on page 1-54. It clarifies that “the original Macintosh character set, as described in Volume I of the original Inside Macintosh” only went up to $d8 (ÿ); “Standard Roman” adds characters from $d9 (Ÿ) up through $FF.
- Ligatures:
	- Æ falls between Å and a
	- æ falls between å and B
	- Œ falls betweeen Ø and o
	- œ falls between ø and P
	- ß falls between s and T
	- It's not at all clear how to make that interoperate with diacritic-stripping and case-folding.
- Stripping of diacritics: Mostly the obvious, plus ø and º map to o, ª to a, and ç to c.
- Case-folding: Letters are folded to the upper case.

The left-to-right ordering of the table seems to suggest that ligature comparison, diacritic-stripping, and case-folding happen in that order.

[Developer Q&A OPS08](https://developer.apple.com/library/archive/qa/ops/ops08.html) mentions that “due to a bug that HFS relies on, back quote sorts between "a" and "b"”.

Apple's open source includes [an implementation of “`FastRelString`” in diskdev_cmds](https://opensource.apple.com/source/diskdev_cmds/diskdev_cmds-491.3/fsck_hfs.tproj/dfalib/SKeyCompare.c.auto.html). This implementation uses a precomputed table, `gCompareTable`, in [CaseFolding.h](https://opensource.apple.com/source/diskdev_cmds/diskdev_cmds-491.3/fsck_hfs.tproj/dfalib/CaseFolding.h.auto.html). The table mostly maps bytes to the same byte shifted 1 byte left; it looks like the high byte is the mapped character (for case-folding) and the low byte is some sort of disambiguator, possibly for diacritics. Let us call these bytes the “integer” and the “fraction”, respectively.

This program analyzes the table and reports any non-identical mappings:

```
enum { gCompareTableLen = 256 };
#error Replace this line with definition of gCompareTable from SKeyCompare.c

int main(int argc, char *argv[]) {
	@autoreleasepool {
		unsigned short lastReportedIndex = 0;
		for (unsigned short i = 0; i < gCompareTableLen; ++i) {
			unsigned short const value = gCompareTable[i];
			//If this isn't an identical mapping of a character to itself, report how it's different.
			if (value != (i << 8)) {
				if (i - lastReportedIndex > 1) {
					printf("\n");
				}

				char const keyBuf[2] = { i, 0 };
				NSString *_Nonnull const keyString = [[NSString alloc] initWithBytesNoCopy:keyBuf length:1 encoding:NSMacOSRomanStringEncoding freeWhenDone:false];
				
				char const convertedBuf[3] = { value >> 8, value & 0xff, 0 };
				NSString *_Nonnull const convertedString = [[NSString alloc] initWithBytesNoCopy:convertedBuf length:2 encoding:NSMacOSRomanStringEncoding freeWhenDone:false];
				printf("0x%02x '%s' => 0x%02x, 0x%02x => '%s' '%s'\n",
					i, [keyString UTF8String],
					value >> 8, value & 0xff,
					[[convertedString substringToIndex:1] UTF8String], [[convertedString substringFromIndex:1] UTF8String]
				);
				lastReportedIndex = i;
			}
		}
	}
	return EXIT_SUCCESS;
}
```

From the output, we can see:

- As documented, '\`' gets folded to 'A', with a fraction of 0x80. It's basically 'A' and a half.
- The lowercase ASCII letters get folded to their uppercase counterparts.
- 0x80 through 0x9f and 0xcb through 0xcf are letters with diacritics, folded to their ASCII letters plus assorted fractions.
- 0xa7, 0xae, 0xaf, 0xbb, 0xbc, 0xbe, and 0xbf are the entries from the ligatures table.
- 0xc7 and 0xc8 and 0xd2 through 0xd5 are quotation marks, folded to the ASCII '"' and '''. The angled quotation marks have a higher fraction than the curly quotes, and within each pair, the closing quote has a higher fraction than the opening quote. The order is “”«»‘’.
- Everything from 0xd9 onward is back to identity mapping. (This even includes 'Ÿ', which is 0xd9. Sure enough, IM:T table 5-2 confirms that 'ÿ' is mapped to 'y' but says nothing of 'Ÿ'.)

The fractions on the diacritic characters seem to correspond to the diacritics:

```
0x6f 'o' => 0x4f, 0x00 => 'O' <nul>
0x85 'Ö' => 0x4f, 0x08 => 'O' <control>
0x9a 'ö' => 0x4f, 0x08 => 'O' <control>
0x9b 'õ' => 0x4f, 0x0a => 'O' <control>
0xcd 'Õ' => 0x4f, 0x0a => 'O' <control>
0xaf 'Ø' => 0x4f, 0x0e => 'O' <control>
0xbf 'ø' => 0x4f, 0x0e => 'O' <control>
0xce 'Œ' => 0x4f, 0x14 => 'O' <unprintable>
0xcf 'œ' => 0x4f, 0x14 => 'O' <unprintable>
0x97 'ó' => 0x4f, 0x82 => 'O' 'Ç'
0x98 'ò' => 0x4f, 0x84 => 'O' 'Ñ'
0x99 'ô' => 0x4f, 0x86 => 'O' 'Ü'
0xbc 'º' => 0x4f, 0x92 => 'O' 'í'
```

Interestingly, à seems to be misaligned, at least in this table:

```
0x88 'à' => 0x41, 0x04 => 'A' ''
0x60 '`' => 0x41, 0x80 => 'A' 'Ä'
0x87 'á' => 0x41, 0x82 => 'A' 'Ç'
```

That middle line is the bug mentioned in OPS08, but the first line is odd. Going by 'ò', it should have a fraction of 0x84.

It seems like the high nybble of 'à''s fraction byte ended up on '\`''s fraction byte instead. I don't know whether the original `RelString` was table-based. As for whether this table is an accurate match to the original `RelString`'s behavior, it's possible to check this as a black box by calling `RelString` on original Mac OS with the following strings:

- 'A', 'à'
- 'à', '\`'
- '\`', 'á'
- 'à', 'á'

`FastRelString`'s table matches `RelString` if `RelString` (case-insensitive, diacritic-distinguishing) returns -1 for each of these pairs.

If original `RelString` instead compares 'à' correctly (as 0x41, 0x84), it should compare _after_ á, as is the case with ò and ó. 

I wrote a small test app in MPW using SIOW:

```
#include <MacTypes.h>
#include <TextUtils.h>

#include <stdio.h>

int main(void) {
	char string0[3] = { 1, 'A', 0 };
	char string1[3] = { 1, 'à', 0 };
	char string2[3] = { 1, '`', 0 };
	char string3[3] = { 1, 'á', 0 };
	printf("'%s' <=> '%s': %d\n",
		string0 + 1, string1 + 1,
		RelString((ConstStr255Param)string0, (ConstStr255Param)string1, false, true)
	);
	printf("'%s' <=> '%s': %d\n",
		string1 + 1, string2 + 1,
		RelString((ConstStr255Param)string1, (ConstStr255Param)string2, false, true)
	);
	printf("'%s' <=> '%s': %d\n",
		string2 + 1, string3 + 1,
		RelString((ConstStr255Param)string2, (ConstStr255Param)string3, false, true)
	);
	printf("'%s' <=> '%s': %d\n",
		string1 + 1, string3 + 1,
		RelString((ConstStr255Param)string1, (ConstStr255Param)string3, false, true)
	);
	return 0;
}
```

The output of this program on Mac OS 9.0.4 is:

```
'A' <=> 'à': -1
'à' <=> '`': -1
'`' <=> 'á': -1
'à' <=> 'á': -1
```

So indeed, the behavior of the open-source `FastRelString` is consistent with Mac OS 9.0.4's `RelString`.

## Growing the catalog file

Catalog records are larger on HFS+ than on HFS:

||Record type  ||HFS bytes ||HFS+ bytes ||Growth factor||
||=============||==========||===========||=============||
||File         ||0x66 (102)||0xf8 (248) || 2.431x      ||
||Folder       ||0x46 (70) ||0x58 (88)  || 1.257x      ||
||File thread  ||0x2e (46) ||0x208 (520)||11.3x        ||
||Folder thread||0x2e (46) ||0x208 (520)||11.3x        ||

(Remember that thread records include the item name. The name went from 32 bytes to hold up to 31 8-bit characters, to 512 bytes to hold up to 255 16-bit code units.)

This necessarily means that the catalog file itself will be larger on an HFS+ volume. The records themselves are larger, and if the source volume did not have thread records for its files, those would need to be added.

In a conversion that upgrades allocation blocks from the old 512 byte minimum size to the new recommended minimum of 4 K, the total number of allocation blocks occupied by the catalog file might change very little (as the average increase in record size is somewhat less than the increase in allocation block size). However, this tool does not do that conversion, so the catalog file will necessarily need to occupy more allocation blocks.

Growing the catalog file is a non-trivial exercise. We can't assume that there is sufficient space to grow the catalog contiguously from its last existing extent. We can't even assume that there is sufficient contiguous space to place the new, larger catalog elsewhere in the volume.

If we are to minimize the relocation of existing allocation blocks, we will need to scatter the new catalog file in every available opening. (One potential new opening is described in the next section.) We want to find the largest contiguous openings, because:

- there might be a single contiguous place to put the whole catalog file, which would be ideal
- there might be enough contiguous places to store the whole catalog file in up to eight extents, which would be second best—no need to add the catalog to the extents overflow file
- if nothing else, we can at least add as few new extents to the extents overflow file as possible

Two parts of finding one or more regions into which to put the catalog file are:

- pretending the old catalog file doesn't exist for the purpose of finding space available for the new one (there's only one catalog file, so the new catalog file can overwrite blocks that were already allocated to the old one)
- reallocating the extents overflow file to a new, potentially smaller (see next section) and maybe more contiguous region

(That last one being made more difficult by the possible need to add extents for the catalog file to it, which, in the worst case, could end up growing the extents overflow file.)

Since catalog records live in the leaf nodes of the catalog B*-tree, we may only need to add leaf nodes to accommodate the larger catalog records, leaving the index nodes unchanged. (Although adding nodes of any kind does require changing, and potentially growing, the map record.) On the other hand, it may be advantageous—or at least a means of potentially offsetting the cost of leaf node growth—to attempt to consolidate index nodes, since the larger B*-tree node size can hold more pointer records. We don't necessarily need to regenerate the whole tree to do that; a single row of index nodes (descending from a parent index node, and following `fLink` connections down the row) should be eligible for consolidation without disrupting or imbalancing the larger tree structure, or affecting any node's `height`.

One thing I've noticed is that there are at least some catalog files that have plenty of free nodes already, which may reduce the need to actually grow the file. (Since the destination volume is intended to be read-only, it's OK if the new catalog file ends up mostly full if it is not grown.))

So catalog file growth is the product of several factors:

- Catalog B*-tree *nodes* grow from 0x200 bytes to a minimum size of 0x1000.
- Catalog *records* grow by varying fixed ratios. Each type of HFS catalog record corresponds to an HFS+ catalog record type, with a larger size.
- Files didn't need thread records in HFS and often didn't have them. HFS+ requires them. That's another 0x40e bytes per thread record (0x206 for the key, 0x208 for the payload).

0x1000 may or may not be the right node size for our purposes. The growth and proliferation of records mean bigger nodes might make sense. If we look at files and folders in terms of the main record plus the thread record, including their keys:

- Files go from 0x26+0x66 = 0x8c bytes (file record only) to 0x206+0xf8+0x206+0x208 = 0x70c bytes, an over 12x increase.
- Folders go from 0x26+0x46+0x26+0x2e = 0xc0 bytes to 0x206+0x58+0x206+0x208 = 0x66c, an eight-and-a-half-times increase.

There is no perfect node size available. Averaging the above, we would want a growth factor of 10x (so 0x1400). B*-tree node sizes are required by TN1150 to be powers of two, so our choices are 0x1000 or 0x2000 (or something even larger).

Nodes that are larger and hold more contents encourage more linear or binary searching of records within a single node. Nodes that are smaller relative to their contents encourage more skipping between nodes (comparing only first and last records to find the right node to search). It's hard to intuitively guess which of these would be the better performance tradeoff, and for a catalog held entirely in memory, it may not make any practical difference. I've probably already wasted more time thinking about it than it would save.

Another factor is waste potential. The larger the node size, the less of it percentage-wise gets wasted.

In the following examples, the usable space of a node (following the node descriptor, which is 0xe bytes in both formats) is 0x1f2 bytes for a 0x200-byte node and 0xff2 for a 0x1000-byte node.

```
“Journeyman Turbo™” contains 381 files and 29 folders
```

This volume contains 0xd05c bytes' worth of file records (assuming no thread records) and 0x15c0 bytes' worth of folder records (including thread records). Count-wise, the ratio is more than 13:1; bytes-wise, the ratio is closer to 9.5:1. 13 file records would occupy a little over three-and-a-half 0x200-byte nodes, leaving just 0xab bytes for that folder record and its thread record, necessitating a fourth node.

Converting to HFS+, those 13 files would occupy 0x5b9c bytes, and the folder another 0x66c, for a total of 0x6208. The files would occupy a little under five-and-three-quarters nodes at 0x1000 bytes each; the remainder, again isn't quite enough for a folder. So we would need at least six nodes to describe these items, a growth of +50%.

```
“Mac OS 9” contains 2703 files and 490 folders
``` 

Count-wise ratio: 5.5:1 (or 11:2). Bytes-wise: 0x5c634 / 0x16f80 = just over 4:1. Let's look at 11 files to two folders.

The 11 files, with no thread records, would occupy 0x604 bytes across just over 3 nodes. The fourth node would probably hold the 11th file, so 0x8c bytes, plus 0xc0 bytes * 2 for the two folders. That's 0x20c bytes, for which that node has ample room, so that's four nodes.

In HFS+, the 11 files go up to 0x4d84 bytes, which would fill a little under 5 nodes. The 0xcd8 bytes for the two folders would spill into a sixth node.

Again the growth, from four nodes to six, is an estimated +50%.

So with each node being eight times the old size, we'll need 50% more leaf nodes. For the following calculations, I'm going to assume that the number of index nodes is relatively negligible.

“Journeyman Turbo™” is using 149 nodes out of an allocated 2046. If we divided the number of nodes by eight to stay close to the old space usage of 62 (large) a-blocks, we get 256 nodes. The +50% node usage will use 224 or so out of those 256 nodes. This catalog file won't need to grow on disk.

“Mac OS 9” is using 1165 nodes out of an allocated 2037. Just looking at those numbers, it's obvious that dividing by eight is a nonstarter; this catalog file will have to grow on disk. It's currently taking up 0xfea00 bytes across 97 a-blocks; 1748 nodes at 0x1000 bytes each will require 0x6d4000 bytes, already nearly a seven-fold increase. Rounded up to the a-block size of 0x2a00, we end up at 0x6d4400.

Fortunately, “Mac OS 9” has 100 MB free, so it can afford the 0x5d5a00-byte (nearly 6 K) increase.

If it couldn't, we could certainly take it out of the extents overflow file, which that volume isn't using:

```
Extents file is using 2 nodes out of an allocated 2037 (0.10% utilization)
```

The two nodes are the header node and maybe one leaf node, so it's basically empty. (If there are no records in the leaf node, then it's totally empty.) The extents file, like the catalog file, has a minimum node size of 0x1000 in HFS+. We can't quite shrink it *all* the way down to 0x2000, but we can shrink it down to one a-block, which is 0x2a00 bytes. That frees up 0x7f2600 bytes, which is more than enough.

### Growing the catalog file revisited: HFS+ catalog keys are variable-sized

The above analysis assumes everything in the catalog has a constant size, which is not true on HFS+.

Catalog keys, in particular, are variable-sized, and will never reach the maximum of 0x208 (520) bytes in a volume converted from HFS+, because most of that is the node name, which has a much higher limit in HFS+ than in HFS. An original HFS+ volume can have node names up to 0x200 (512) bytes (255 characters * 2 bytes each + 2-byte length value), whereas an HFS volume limits node names to 31 characters, which is 0x40 (64) bytes after conversion.

Among catalog records, only thread records have a node name—but this, too, is variable-sized, according to hfs_format.h. Here, too our maximum size drops precipitously.

Let's revisit the analysis from earlier, assuming names using all 31 characters that HFS allowed them:

- The HFS+ catalog key is 0x2+0x4+0x40=0x46 bytes. The HFS+ thread record is 0x2+0x2+0x4+0x40=0x48 bytes. 
- Files go from 0x26+0x66 = 0x8c bytes (file record only) to 0x46+0xf8+0x46+0x48 = 0x1cc bytes, an over 3x increase.
- Folders go from 0x26+0x46+0x26+0x2e = 0xc0 bytes to 0x46+0x58+0x46+0x48 = 0x12c, a one-and-a-half-times increase.

Now this looks much better. Even with the addition of file thread records, the growth of catalog nodes by a factor of 8 provides more than enough room for this growth.

Of course, that assumes there's enough room on disk to accommodate the growth in node size. The good news is, even in the worst case, the catalog file only needs to grow (in bytes) by less than 4x, not the full 8x.

Most of this growth is in the leaf nodes, where all the file and folder and thread records live. We might not need as many of them, because they're bigger by a larger factor than their contents; we can fit more items per node.

The same is true of the index nodes, although the feasibility of removing any is still an open question, without a full B*-tree implementation. But consolidation among leaf nodes means index nodes might end up with some redundant entries (pointing to the same descendant), or just empty space.

## Shrinking (or even emptying) the extents overflow file

HFS+ does a lot to reduce the need for overflow extents:

- Extents themselves have greater range, having been upgraded from 16-bit to 32-bit values, so a single extent can address a larger contiguous range of blocks (particularly valuable in our case, if we preserve HFS's relatively tiny 512-byte blocks)
- That means that consecutive adjacent extents could be consolidated down to a single extent
- Extent records are expanded from 3 extents to 8, which pulls up to 5 (or more with consolidation) overflow extents out of overflow

The first point alone means that, given 512-byte blocks, the maximum size of a single extent goes from 65,535 blocks (33,553,920 bytes, or just under 32 MB), to 2^31 blocks (1,099,511,627,776 bytes, or 1 TB). Large files such as disk images, PSDs, audio files, and movie files may be particularly likely to hit the former cutoff even if occupying a single contiguous range of blocks; these files would be eligible for extent consolidation.

Extents can be safely consolidated if they are both consecutive and adjacent. The former refers to the order in the extent record (plus any overflow records): the first and second extents are consecutive, as are the second and third, etc. The latter refers to their placement on disk; two extents are adjacent if the block immediately after the end of the first extent is the first block of the second extent. The former is necessary to avoid wrongly consolidating adjacent but non-consecutive extents and thereby rearranging a file's contents; the latter is necessary because a single extent can only represent one contiguous range.

Whether or not any extents are consolidated, the growth of extent records means some extents will need to be moved from the overflow file, since an empty extent is considered the end of the file, which means we can't have five empty extents at the end of the catalog record's extent record.

Only severely fragmented files might have more than eight extents, and some of these may be eligible for consolidation, which might bring them down to eight or fewer. Files that had more than 3 extents in the HFS volume, and have 8 or fewer extents (after consolidation) in the HFS+ volume, must be removed from the extents overflow file.

On HFS volumes that have an extents overflow file, its shrinkage is likely to be severe and potentially total. One benefit of this is freeing up space for the catalog file; either freeing up space entirely, or being relocatable to a smaller opening in the HFS+ volume.

Of course, in a defragmenting conversion (not attempting to preserve data's location on disk), no file should end up overflowing a single HFS+ extent record. Between the greater ranges, the increase in the number of extents per record, and the defragmentation, almost all files will end up in one extent and the very largest files should end up in a handful of adjacent extents. The extents overflow file after such a conversion should be empty.

## Observed VBM ranges

(I eventually solved this mystery. Skip to the end.)

It's been a bit tricky to figure out where the VBM should begin and end. We know, based on IM:F and TN1150, that:

- the VBM starts at block #3 (immediately after the volume header)
- other than that, the VBM's size/range is not directly indicated anywhere, but it must be at least drNmAlBlks (number of allocation blocks in the volume) bits in size
- the VBM is stored in 512-byte blocks (not allocation blocks, unlike on HFS+)
- the VBM is contiguous (unlike on HFS+)

So it starts at block #3 and runs contiguously for some number of 512-byte blocks.

Knowing where the VBM _ends_ is important because that's the start of the first allocation block, which we need to know in order to reliably find the blocks that hold the catalog file, the extents overflow file, and everything else.

Unfortunately, this has proven to be a game of whack-a-mole. Getting some images working keeps causing others to flake out. The following data is an attempt to find a pattern from which to develop a reliable rubric. Values are in bytes (0x200 = 512 bytes).

- 40 MB Mini vMac image: VBM minimum size in bytes is number of blocks 40951 / 8 = 0x13ff; Allocation block size is 0x400 (0x200 * 2.0); Clump size is 0x1000 (0x200 * 8.0; ABS * 4.0); VBM starts at 0x600, runs for 0x1400 (5.0 blocks), ends at 0x1a00
- Quake 3 Arena CD-ROM: VBM minimum size in bytes is number of blocks 63189 / 8 = 0x1edb; Allocation block size is 0x2000 (0x200 * 16.0); Clump size is 0x2000 (0x200 * 16.0; ABS * 1.0); VBM starts at 0x600, runs for 0x2000 (1.0 blocks), ends at 0x2600
- Disk Copy 6.3.3: VBM minimum size in bytes is number of blocks 5113 / 8 = 0x280; Allocation block size is 0x200 (0x200 * 1.0); Clump size is 0x800 (0x200 * 4.0; ABS * 4.0); VBM starts at 0x600, runs for 0x400 (2.0 blocks), ends at 0xa00
- Descent 1 CD-ROM (INCORRECT result): VBM minimum size in bytes is number of blocks 39984 / 8 = 0x1386; VBM minimum size in bytes is number of blocks 39984 / 8 = 4998; Allocation block size is 0x200 (0x200 * 1.0); Clump size is 0x800 (0x200 * 4.0; ABS * 4.0); VBM starts at 0x600, runs for 0x1400 (10.0 blocks), ends at 0x1a00
- Descent 1 CD-ROM (CORRECT result): … VBM starts at 0x600, runs for 0x1600 (11.0 blocks), ends at 0x1c00
- Journeyman Project Turbo! (INCORRECT result): VBM minimum size in bytes is number of blocks 40300 / 8 = 0x13ae; Allocation block size is 0x4200 (0x200 * 33.0); Clump size is 0x10800 (0x200 * 132.0; ABS * 4.0); VBM starts at 0x600, runs for 0x3e00 (0.9 blocks), ends at 0x4200 (This result was based on trying to pad the VBM end out to an allocation block boundary)
- Journeyman Project Turbo! (INCORRECT result): VBM minimum size in bytes is number of blocks 40300 / 8 = 0x13ae; Allocation block size is 0x4200 (0x200 * 33.0); Clump size is 0x10800 (0x200 * 132.0; ABS * 4.0); VBM starts at 0x600, runs for 0x1400 (0.3 blocks), ends at 0x1a00

The incorrect result for Descent is that we look for the extents overflow and catalog files one block earlier than where they actually are. Since the first node of a B*-tree file is the header node, finding any other kind of node there means we're looking in the wrong place. Descent's volume header says that the header node of its EO file is at allocation block 0, and the header node of its catalog file is at block 328. Empirically, the EO header node is at 0x1c00. With a hack in place to make the math work out to that, both header nodes are found and the catalog file parses successfully.

I'm as yet unsure why Descent needs an extra block after where the VBM seemingly should end.

I'm tempted to just iterate forward one allocation block at a time until I find a header node, but there's not actually any guarantee that either header node is at allocation block 0. Arguably I could take the lesser of the two block numbers—let's say it's allocation block #5—and call the allocation block 5 blocks behind the first wild header node block 0.

I had thought it might be based on the clump size, but the Mini vMac image has the VBM neither start on a clump boundary, nor run for a whole number of clumps, nor end on a clump boundary. So much for that.

As for The Journeyman Project, its catalog file appears (just from looking at the hex dump) to start possibly at 0x102400, which is 2,066 512-byte blocks into the file. (JMP's allocation block size is, as noted above, fairly huge, as it's a nearly-full CD-ROM.) Interestingly, that's 62.6 allocation blocks into the file.

Perhaps the first allocation block has to be on an allocation block boundary? Certainly wouldn't help with Descent, whose allocation block size is only 512 bytes, and yet it needs an extra 512 before the first allocation block.

Like Descent, JMP's catalog file immediately follows its extents file:

```
Catalog extent the first: start block #62, length 62 blocks
Catalog extent the second: start block #0, length 0 blocks
Extents overflow extent the first: start block #0, length 62 blocks
Extents overflow extent the second: start block #0, length 0 blocks
```

62 allocation blocks is 0xffc00 bytes, or 1,047,552—just under 1 MiB, which is 1,048,576. (In fact, it's 1 MiB minus 1 KiB, or 1,023 KiB.)

So if the catalog starts at 0x102400, then the EO file should start 0xffc00 before that, which is 0x2800. There doesn't seem to be a header node there, though.

There *does* seem to be a header node at 0x2600, 0x200 earlier than 0x2800 but still much farther out than 0x1a00 (specifically, a difference of +0x0e00, or 7 * 0x200).

… and then I finally noticed the `drAlBlkSt` (allocation block start) member of the volume header. It's the location of allocation block 0, in 512-byte units. It's exactly what I needed, but I missed it because I was assuming that the end of the VBM was necessarily the beginning of allocation block 0, and that's not the case.

Using `drAlBlkSt` * 0x200 is exactly the reliable solution that was missing.

## Possible future directions: Subcommands

The primary purpose of this tool is to convert HFS volumes to HFS+, but there are a variety of things one could do once the core functionality is implemented, and the process of building this tool—with debug logging that inspects the contents discovered, to verify that the HFS parsing is working—has inspired some ideas. Possibilities include:

- `upgrade hfsvol hfsplusvol`: The main event, converting an HFS volume as-verbatim-as-possible to an HFS+ volume.
- `probe hfsvol`: Test whether something is an HFS volume. If it is, report its name and a few easy-to-obtain statistics.
- `list [-f|-d] hfsvol`: List the files and(/or) folders of an HFS volume, regardless of hierarchy.
- `tree hfsvol [name|path]`: List the entire folder hierarchy. With a name or path, list the tree descending from that folder, if a folder exists at that path or is uniquely identified by that name.
- `extract hfsvol [name|path]`: Copy the contents of the volume, or a single file, or a single folder with all of its descendants, from the HFS volume into the real world. At this point we start to treat HFS volumes like archive files. If no name or path is given, the entire volume is unarchived as a folder.
- `sftp hfsvol`: (Or maybe `interactive` or something.) Start an interactive shell (implemented with macOS's imitation `readline`), with commands most likely mimicking `sftp`. `lls` and `lcd` would interact with the real world, while `ls`, `cd`, and `get` would interact with the HFS volume. Whether `put` is included depends on how trivial it would be to add based on whatever behind-the-scenes functionality we have by that point (particularly, ability to create/mutate HFS volumes).
- `archive localfolder hfsvol`: Create an HFS volume with the contents of a real folder. Would certainly need handling of various features that can't be represented in HFS: long filenames, extended attributes, etc. Some can be silently dropped because they can't reasonably be persisted, but long filenames will be tricky. Could fail hard, or silently truncate, or borrow the Windows 95 solution of “Blah Blah Blah~1”. Files without type and creator codes would need them added (Launch Services might be able to help with at least some of that, though some translation to common Classic Mac creator codes might still be needed). Also, we'll need to fail hard for files too large or numerous to be encoded in an HFS volume. Hardest part might be needing to build a reasonable B*-tree from scratch, not having an existing one to copy off of.
- `downgrade hfsplusvol hfsvol`: Of course, once we can create HFS volumes, that's 50% of the way to being able to go the opposite direction from the one we started in. We would have to be able to parse HFS+ (structurally similar to parsing HFS), and handle the various data-loss cases, and consolidate the allocations file down to one contiguous VBM. And, of course, there's the question of how useful it is to do that, versus mounting the HFS+ disk image and then using `archive`. Maybe if HFS+ ever gets dropped in some future, APFS-only macOS.

Also, not a subcommand, but it would probably be helpful to at least be able to pierce through Apple Partition Maps, if not necessarily understand them properly or deal with multiple partitions. Many whole-disk images start with an APM. Rather than make the user strip that off/extract the HFS partition, it'd be much more convenient for this tool to do that automatically. (A brute-force method would be to flip through the file 512 bytes at a time until the 'BD' signature word is encountered, then back off by 1 KiB.)

## Navigating the catalog B*-tree in the debugger

ImpBTreeNode has an 'inventory' method that prints out the node's keyed records, which is *very* handy for navigating the catalog manually. Here's a sample session, building the path to the “JM Turbo™” executable on the Journeyman Project Turbo! CD:

```
-- Looking for parent #44 name “JMP Turbo™”

(lldb) po rootNode.inventory
<__NSArrayM 0x1012169d0>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: Pointer to node #127,
Catalog key [parent ID #155, node name “Mars Robot Down Kill.QT”]: Pointer to node #15
)

127

(lldb) po [self nodeAtIndex:127].inventory
<__NSArrayM 0x101123c90>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: Pointer to node #146,
Catalog key [parent ID #26, node name “”]: Pointer to node #14,
Catalog key [parent ID #47, node name “”]: Pointer to node #27,
Catalog key [parent ID #75, node name “JMP type w/ mark .PRINT1”]: Pointer to node #51,
Catalog key [parent ID #91, node name “Sepiatone”]: Pointer to node #126,
Catalog key [parent ID #95, node name “Dr Shoots You.QT”]: Pointer to node #39,
Catalog key [parent ID #113, node name “Space Sounds AIFF”]: Pointer to node #58
)

14

(lldb) po [self nodeAtIndex:14].inventory
<__NSArrayM 0x101216cd0>(
Catalog key [parent ID #26, node name “”]: Pointer to node #7,
Catalog key [parent ID #26, node name “Journeyman Looping Demo”]: Pointer to node #8,
Catalog key [parent ID #26, node name “Pteradactyl fly.QT”]: Pointer to node #9,
Catalog key [parent ID #36, node name “”]: Pointer to node #10,
Catalog key [parent ID #36, node name “Notes for Extensions Mgr 2.0.1”]: Pointer to node #11,
Catalog key [parent ID #36, node name “Sound Manager Read Me”]: Pointer to node #13
)
(lldb) po [self nodeAtIndex:14].nextNode.inventory
<__NSArrayM 0x10103a480>(
Catalog key [parent ID #47, node name “”]: Pointer to node #24,
Catalog key [parent ID #47, node name “Journeyman Promo Images”]: Pointer to node #16,
Catalog key [parent ID #49, node name “After Pre”]: Pointer to node #17,
Catalog key [parent ID #49, node name “Icon
”]: Pointer to node #18,
Catalog key [parent ID #49, node name “Mars Lower after robot”]: Pointer to node #19,
Catalog key [parent ID #49, node name “Norad after silo game”]: Pointer to node #20,
Catalog key [parent ID #49, node name “Prehistoric”]: Pointer to node #21,
Catalog key [parent ID #49, node name “TSA After RR”]: Pointer to node #22,
Catalog key [parent ID #49, node name “TSA Main after Prehistoric”]: Pointer to node #23,
Catalog key [parent ID #49, node name “WSC begin”]: Pointer to node #25,
Catalog key [parent ID #75, node name “Icon
”]: Pointer to node #26
)

13

(lldb) po [self nodeAtIndex:13].inventory
<__NSArrayM 0x10103bf60>(
Catalog key [parent ID #36, node name “Sound Manager Read Me”]: 📄 [ID #43, type 'ttro', creator 'ttxt'],
Catalog key [parent ID #44, node name “”]: 🧵 📁 [parent ID #2, name “Please Copy to Hard Drive”],
Catalog key [parent ID #44, node name “Icon
”]: 📄 [ID #45, type '', creator ''],
Catalog key [parent ID #44, node name “JMP Turbo™”]: 📄 [ID #46, type 'APPL', creator 'PJ93']
)

Found thread record:
Catalog key [parent ID #44, node name “”]: 🧵 📁 [parent ID #2, name “Please Copy to Hard Drive”],

Found file record:
Catalog key [parent ID #44, node name “JMP Turbo™”]: 📄 [ID #46, type 'APPL', creator 'PJ93']
```

### OBSERVATIONS
- Conjecture: The thread record's name is always empty, which makes it always the first record with a given parent ID.
- Because all the leaf nodes are one tier in sorted order, we can scroll backward to find the thread record.
- Finding the thread record then gives us the parent directory's name and *its* parent directory's number.

In this case, JMP Turbo™ has parent #44; the thread record for #44 says its name is “Please Copy to Hard Drive” and its parent is #2 (the root directory).

```
Looking for parent #2 name “Please Copy to Hard Drive”

(lldb) po rootNode.inventory
<__NSArrayM 0x10103e7f0>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: Pointer to node #127,
Catalog key [parent ID #155, node name “Mars Robot Down Kill.QT”]: Pointer to node #15
)

127

(lldb) po [self nodeAtIndex:127].inventory
<__NSArrayM 0x101217cd0>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: Pointer to node #146,
Catalog key [parent ID #26, node name “”]: Pointer to node #14,
Catalog key [parent ID #47, node name “”]: Pointer to node #27,
Catalog key [parent ID #75, node name “JMP type w/ mark .PRINT1”]: Pointer to node #51,
Catalog key [parent ID #91, node name “Sepiatone”]: Pointer to node #126,
Catalog key [parent ID #95, node name “Dr Shoots You.QT”]: Pointer to node #39,
Catalog key [parent ID #113, node name “Space Sounds AIFF”]: Pointer to node #58
)

146

(lldb) po [self nodeAtIndex:146].inventory
<__NSArrayM 0x101126200>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: Pointer to node #145,
Catalog key [parent ID #2, node name “Desktop DB”]: Pointer to node #5,
Catalog key [parent ID #2, node name “JMP Turbo READ ME”]: Pointer to node #12,
Catalog key [parent ID #2, node name “Please Copy to Hard Drive”]: Pointer to node #147,
Catalog key [parent ID #2, node name “Support Files”]: Pointer to node #2,
Catalog key [parent ID #18, node name “”]: Pointer to node #4,
Catalog key [parent ID #18, node name “Demo Movie 05.qt CPK ms”]: Pointer to node #6
)

147

(lldb) po [self nodeAtIndex:147].inventory
<__NSArrayM 0x101040270>(
Catalog key [parent ID #2, node name “Please Copy to Hard Drive”]: 📁 [ID #44, 2 items],
Catalog key [parent ID #2, node name “PR Stuff”]: 📁 [ID #47, 3 items]
)

Scrolling backwards to find the thread record…

(lldb) po [self nodeAtIndex:147].previousNode.inventory
<__NSArrayM 0x1011272d0>(
Catalog key [parent ID #2, node name “JMP Turbo READ ME”]: 📄 [ID #25, type 'TEXT', creator 'MSWD'],
Catalog key [parent ID #2, node name “Journeyman Demo”]: 📁 [ID #26, 9 items],
Catalog key [parent ID #2, node name “Journeyman Turbo Manual”]: 📄 [ID #422, type 'TEXT', creator '????'],
Catalog key [parent ID #2, node name “Optional System Stuff”]: 📁 [ID #36, 7 items]
)

(lldb) po [self nodeAtIndex:147].previousNode.previousNode.inventory
<__NSArrayM 0x1011284d0>(
Catalog key [parent ID #2, node name “Desktop DB”]: 📄 [ID #17, type 'BTFL', creator 'DMGR'],
Catalog key [parent ID #2, node name “Desktop DF”]: 📄 [ID #16, type 'DTFL', creator 'DMGR'],
Catalog key [parent ID #2, node name “Desktop Folder”]: 📁 [ID #425, 0 items],
Catalog key [parent ID #2, node name “Icon
”]: 📄 [ID #423, type '', creator '']
)

(lldb) po [self nodeAtIndex:147].previousNode.previousNode.previousNode.inventory
<__NSArrayM 0x10070c770>(
Catalog key [parent ID #1, node name “Journeyman Turbo™”]: 📁 [ID #2, 15 items],
Catalog key [parent ID #2, node name “”]: 🧵 📁 [parent ID #1, name “Journeyman Turbo™”],
Catalog key [parent ID #2, node name “Buried in Time™ Demo”]: 📁 [ID #18, 6 items]
)

Found thread record:
Catalog key [parent ID #2, node name “”]: 🧵 📁 [parent ID #1, name “Journeyman Turbo™”],
```

### Observations
We don't necessarily need to look up the name of ID #2; we know it's the root directory, and HFS (unlike HFS+) encodes the volume name in the volume header.

## HFS+ upgrade process

### What we could do when the allocation block size is 0x200

This sketch might work when the allocation block size is 0x200 but won't work otherwise, for reasons discussed above in the VBM section. This sketch doesn't cover changing the block size and the adjustments required.

0. Start the block copy.
0.5. Also open the second file handle for writing at the destination that will be used for overwriting HFS bits with HFS+ bits. We need to keep a file handle open while the block copy is in progress so DiskArb doesn't try to mount the HFS volume if the block copy ends before we we've finished translating. (Particularly on older systems where HFS is still supported natively.)
1. Translate the MDB into the HFS+ volume header.
2. Translate the HFS extents into HFS+ extents, consolidating extents when possible and removing fork records from the extents overflow file when necessary. (Most conversions will leave the extents overflow file empty except in cases of severe fragmentation.)
	- Extent starts also need to be adjusted.
3. Translate the HFS catalog records in the catalog file into HFS+ catalog records.
	- This includes not only rewriting the records in the leaf nodes, but also updating pointer nodes, as the catalog node size and catalog record sizes grew by disparate factors.
	- Extent starts also need to be adjusted.
4. Note the differences in the sizes of the catalog and extents overflow files. Allocate further blocks to grow these files when necessary, in the following order:
	1. If the catalog file has grown and the EO file has shrunk, reallocate allocation blocks from the EO file to the catalog file. (In many cases, this can be done by adjusting their singular extents without any other changes.)
	2. If both files have grown, attempt to grow them contiguously.
	3. If they can't be grown contiguously, allocate new blocks from those available and add their extents to the relevant extent records.
		1. Try for a single new extent of the minimum contiguous length to hold the new blocks, as early as possible in the file. (So not simply the biggest contiguous free space. Scan forward until a big-enough free space is encountered, then draw a new extent from that.)
		2. If no single contiguous range of free blocks exists, build multiple new extents in the available free ranges, in descending order from biggest to smallest.
4.1. Note that allocating new blocks includes setting the corresponding bit(s) in the allocations file.
5. Write the new catalog and extents overflow files to their updated lists of extents.
6. Write the allocations file.

### When the allocation block size isn't 0x200

Some volumes (larger ones) have block sizes larger than 0x200. I expect they're all multiples of 0x200, since a “physical block” is defined by IM:F to be 0x200 bytes. But they're not necessarily power-of-two multiples. “Journeyman Turbo™”'s block size is 0x4200, which is 0x200 * 33.

In HFS, the volume header and volume bitmap come before the first block, whereas in HFS+, they are in the first block(s). This means that, at minimum (with 0x200-byte blocks), every extent's start needs to be changed to accommodate the shift—what was block 0 becomes block 3. For other block sizes, the shift might be larger, as the boot blocks+volume header might need to be padded out to a full allocation block. 

Here's the Mac OS 9.0.4 install CD:

```
VBM minimum size in bytes is number of blocks 63096 / 8 = 0x1ecf
Allocation block size is 0x2a00 (0x200 * 21.0)
Clump size is 0xa800 (0x200 * 84.0; ABS * 4.0)
VBM starts at 0x600, runs for 0x2000 (0.8 blocks), ends at 0x2600
First allocation block: 0x2600
Space remaining: 9370 blocks (0x6014400 bytes)
Reading 0xfea00 bytes (1042944 bytes = 97 blocks) from source volume starting at 0x2600 bytes (extent: [ start #0, 97 blocks ])
Extents file data: 0xfea00 bytes (97 a-blocks)
Extents file is using 2 nodes out of an allocated 2037 (0.10% utilization)
Reading 0xfea00 bytes (1042944 bytes = 97 blocks) from source volume starting at 0x101000 bytes (extent: [ start #97, 97 blocks ])
Catalog file data: 0xfea00 bytes (97 a-blocks)
Catalog file is using 1165 nodes out of an allocated 2037 (57.19% utilization)
```

If we hypothetically converted this to HFS+ with the same a-block size, the boot blocks and volume header would (by necessity) have the first a-block all to themselves, occupying the first 0x2a00 bytes of the volume. This already pushes the start of *anything else* down by 0x400 bytes.

The volume bitmap is 0x1ecf bytes; with a couple more a-blocks added at the start and end, it would be 0x1ed1. (This would necessitate shifting everything down by exactly one bit, but we'll leave that aside for now.) That will fit neatly in one a-block somewhere, which is another 0x2a00 bytes, running from 0x2a00 to 0x5400.

In the HFS volume, the extents file starts at 0x2600. In the HFS+ volume, it would move down by nearly 5 K to 0x5400.

A key concept that emerges from all of this is the “first user allocation block”. The FUAB is the first a-block in which the catalog file, extents overflow file, attributes file (in HFS+), and user files may live. (I'm not including the allocations file for reasons which will hopefully become clear.)

The purpose of the FUAB is twofold:

1. Given that user data files (and the catalog and extents files) start at X offset into the HFS volume, what Y offset into the HFS+ volume do we block-copy all of that data to?
2. What delta (in a-blocks) do we need to add to those files' extents' starts? (This delta is at least 1, for block size 0x600 and larger, if the allocations bitmap is moved down among the UABs. For block size 0x200, it is at least 3.)

(It's worth noting that question #1 *may not be answerable* in terms of a single block-copy. If there are occupied UABs at or sufficiently close to the end of the volume, shifting the UABs down may push user data off the bottom edge where the alternate volume header starts. At that point, we would need to either try a smaller a-block size that might free up enough space, or if that still fails, fall back to a more-careful, file-by-file, defragmenting copy.)

The FUAB in an HFS volume is the block starting at `drAlBlSt`, often but not necessarily immediately after the VBM. The FUAB in HFS+ *can be* the block starting immediately after the volume header, at 0x600, if the allocations file is moved into formerly-free UABs.

The first *user* allocation block is distinct from the first allocation block in HFS+. The first allocation block is the first `blockSize` bytes of the volume, containing at least the first boot block and possibly both boot blocks + the volume header + leftover space if the block size is big enough. I'm also not counting the allocation file's a-blocks as user a-blocks; if the allocation file is kept in its HFS-style position before the first user a-block, the first user a-block need to slide downward to 

HFS+ conversion that attempts to preserve positions as much as possible may need to:

- allocate the first a-block to the boot blocks + volume header
- allocate the second a-block (and possibly more blocks than that) to the allocations file
- add bits to the allocations bitmap to reflect the new a-blocks before and after the user a-blocks; this may get tricky if there are not a multiple of eight new a-blocks
- block-copy from the HFS volume to the HFS+ volume, with different start offsets reflecting where their FUABs start
- generate an allocations bitmap that:
	- shifts the bits down to add new bits for the a-blocks occupied by the boot blocks, volume header, and allocations file (formerly VBM)
		- (the shift will be non-trivial effort since it will be a multiple of 8 only 1/8th of the time)
		- the a-block(s) occupied by the boot blocks and volume header would be set; the allocations file a-blocks should be clear for now
	- sets at least one new bit at the end for the alternate volume header
	- turns off the a-blocks formerly allocated to the catalog and extents files
	- is larger by one (1) a-block if necessary
- allocate a-blocks anew to the allocations file, catalog file (grown), and extents file (shrunken, very likely empty even if it wasn't already)

It may not make sense, for volumes with large a-block sizes, to try to keep the allocations bitmap between the volume header and UABs. Such volumes may have a larger a-block size than the size of their allocations bitmap (examples: Mac OS 9.0.4 has a-block size 0x2a00 and VBM size 0x2000; “The Journeyman Project” Turbo! has a-block size 0x4200 and VBM size 0x1400). In these cases, it may make more sense to move the FUAB offset *up* to the second a-block, and find somewhere in the middle of UAB space to put the allocations file. One weird trick—rotational media hate it.

Growing the allocations bitmap may end up adding another byte to it. Adding another byte to it may (in the worst case) necessitate allocating a whole new a-block. 

## A wild idea: Converging worlds

I've settled on implementing a defragmenting conversion, at least first, as it seems to be simpler/have fewer edge cases than attempting to preserve block allocations.

So now I need to allocate blocks afresh. Allocating blocks means marking the corresponding bits as used in the VBM/allocations bitmap and returning the extent that identifies those blocks, to be added to an extent record in a file's catalog record or the extents overflow file (or, for the special files themselves, in the volume header).

One idea I've been toying with is having two separate allocation directions.

The standard HFS/HFS+ algorithm allocates forward, starting from the block identified by `nextAllocation` (or, if that fails, from the FUAB), until an available extent is found. My version of this attempts to find the smallest single available extent that will fit the request, falling back to smaller allocations if necessary.

What I'm toying with is doing that only for the special files (catalog, etc.) and the resource forks. Data forks would be allocated in the opposite direction from the opposite end.

This would keep most of the smallest forks down at the low (hub-ward, on a spinning platter) end of the volume, and allocates the largest forks at the high (radial) end.

There would be two `nextAllocation` fields. One, the one stored in the volume header, would be the one used for resource forks and special files (advancing forward). The other would be used for data forks and would advance backward. As `nextAllocation` is the block number where the most recently allocated (resource) extent starts, `nextDataAllocation` would be the block number of the last block of the most recently allocated data extent.

It may also make sense to set a computed border between these two block numbers on every search, and stop the search if it would cross the border. Then a data fork would never receive extents in the resource region, nor vice versa.

It's possible, maybe even likely, that this isn't worth the trouble. (Certainly not on Mac OS X volumes, which tend to be more data-fork-heavy.)
