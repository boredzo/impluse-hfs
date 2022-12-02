#  A collection of notes, insights, knowledge gained, etc.

## Further reading

- HFS is defined in [the “File Manager” chapter of Inside Macintosh: Files](https://developer.apple.com/library/archive/documentation/mac/pdf/Files/File_Manager.pdf), under “Data Organization on Volumes”.
- HFS+ is defined in [TN1150, “HFS Plus Volume Format”](https://developer.apple.com/library/archive/technotes/tn/tn1150.html).
- There are a few HFS-related Developer Q&As and technotes in [the documentation archive](https://developer.apple.com/library/archive/navigation/).
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

This means that the volume bitmap is always in 512-byte chunks, regardless of `drAlBlkSize`.

>All of the volume's structures, including the volume header, are part of one or more allocation blocks (with the possible exception of the alternate volume header, discussed below). This differs from HFS, which has several structures (including the boot blocks, master directory block, and bitmap) which are not part of any allocation block.

This part has two ramifications:

- The first allocation block on an HFS volume starts after the VBM. (Though, does it have to start at a position that is a multiple of the block size? That is, if the VBM's last 512-byte chunk ends on a multiple of 512 but not 1024, does there need to be padding between that point and the next allocation-block-size multiple?)
- Including everything all the way out to the edges of the volume changes _which_ blocks have to be marked as used. Effectively, the allocation bitmap on HFS+ has a handful of new blocks, marked as used, before and after the volume contents.

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

## Catalog records

There are four kinds of records in a catalog leaf node:

- file
- folder/directory
- file thread
- folder thread

A file or folder record describes the metadata of the item itself (e.g., its creation and modification dates, as well as Finder info such as type and creator codes). A file record also includes the extents of the file's data and resource forks.

Thread records relate a file or folder to its parent, and also give the file or folder's name. (This does mean that, on HFS+, thread records are actually larger than catalog records!)

TN1150 notes that HFS does not require a file to have a thread record, but HFS+ does.

## Growing the catalog file

Catalog records are larger on HFS+ than on HFS:

||Record type  ||HFS bytes||HFS+ bytes||Growth factor||
||=============||=========||==========||=============||
||File         ||102      ||248       || 2.431x      ||
||Folder       ||70       ||88        || 1.257x      ||
||File thread  ||46       ||520       ||11.3x        ||
||Folder thread||46       ||520       ||11.3x        ||

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
