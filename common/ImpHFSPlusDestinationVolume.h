//
//  ImpHFSPlusDestinationVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpDestinationVolume.h"

#import <hfs/hfs_format.h>

@interface ImpHFSPlusDestinationVolume : ImpDestinationVolume

@property(nonatomic, copy) NSData *_Nonnull bootBlocks;
@property(nonatomic, copy) NSData *_Nonnull lastBlock;
@property(nonatomic, copy) NSData *_Nonnull volumeHeader;

- (void) peekAtHFSPlusVolumeHeader:(void (^_Nonnull const)(struct HFSPlusVolumeHeader const *_Nonnull const vhPtr NS_NOESCAPE))block;

///For use by HFS-to-HFS+ converter objects to make changes to the HFS+ volume header during conversion.
- (struct HFSPlusVolumeHeader *_Nonnull const) mutableVolumeHeaderPointer;

#pragma mark Allocating blocks

///Calculate the minimum physical length in blocks for a fork of a given logical length in bytes.
- (u_int64_t) countOfBlocksOfSize:(u_int32_t const)blockSize neededForLogicalLength:(u_int64_t const)length;

///Set the size of each allocation block, and the total number of them. As allocation blocks in HFS+ span from the boot blocks to the footer, this sets the size of the volume.
///You should not call this method after anything that has allocated blocks past the volume header (including populating the catalog file), because this method creates the allocations bitmap and initializes it to allocate only the minimum set of a-blocks (those containing the volume header and other required sectors and nothing else).
///aBlockSize must be a multiple of kISOStandardBlockSize (0x200 bytes), and a power of two.
- (void) initializeAllocationBitmapWithBlockSize:(u_int32_t)aBlockSize count:(u_int32_t)numABlocks;

///Convenience method that adds enough blocks to contain the required sectors (volume header, etc.) that aren't considered allocation blocks under HFS. For large block sizes, this may add as few as two blocks; for the smallest block size of 0x200 bytes, it will add five (two for the boot blocks, a third for the volume header, and two more at the end for the alternate volume header and the footer).
- (void) setAllocationBlockSize:(u_int32_t)aBlockSize countOfUserBlocks:(u_int32_t)numABlocks;

///Walks through the in-progress allocations file counting up free blocks, and returns the count. This is used to update the volume header after changes that may allocate or deallocate blocks.
///(Note that this is used when *creating* HFS+ volumes, whereas the superclass method with a similar name and purpose is for volumes being *read in*.)
- (u_int32_t) numberOfBlocksFreeAccordingToWorkingBitmap;

///Given a volume length, return a valid block size that will be usable for a volume of that size.
///HFS+ (TN1150) requires block sizes to be a multiple of 0x200 and a power of two. This method will find the smallest block size that fits those constraints.
+ (u_int32_t) optimalAllocationBlockSizeForVolumeLength:(u_int64_t)numBytes;

/*!Attempt to allocate a contiguous range of available blocks. Writes the range allocated to the given extent.
 * Returns true if a contiguous extent containing this number of blocks was allocated. Returns false (without making any changes to existing allocations) if the request could not be fulfilled because not enough contiguous blocks were available.
 * You can pass an extent that is not empty, and this method will attempt to extend it contiguously forward. If that succeeds, blockCount will change but not startBlock.
 * If there aren't enough blocks forward of the existing extent, this method will attempt to extend it backward. If that succeeds, startBlock will change, not necessarily by blockCount (the method may extend the extent both backward and forward if necessary).
 * If there aren't enough blocks on either side of the existing extent, this method will seek a large enough opening somewhere else. If it finds one, it will allocate those blocks, deallocate the blocks previously referenced by the extent, and overwrite both startBlock and blockCount.
 * A corollary of the above is that you must not assume any blocks covered by the extent before this method are still covered by it after this method.
 * This method does not associate the returned extent with a file. It assumes you're doing that.
 */
- (bool) allocateBlocks:(u_int32_t)numBlocks
	forFork:(ImpForkType)forkType
	getExtent:(struct HFSPlusExtentDescriptor *_Nonnull const)outExt;

/*!Convenience method wrapping allocateBlocks:forFork:getExtent:. Attempts to fill one extent record with up to eight extents big enough to hold the requested length.
 *Returns 0 if the request was entirely fulfilled and the extent record now contains extents covering enough blocks to fully hold a file of this length. Otherwise, returns the number of bytes that don't yet have a home. Create a new extent record (for the extents overflow file) and call this method again with the remaining length.
 *Only the last non-empty extent in the record may be changed; others are assumed to already be optimal and will be left alone. The last non-empty extent may be extended or reallocated as described under allocateBlocks:forFork:getExtent:. If that isn't enough, this method will allocate further extents until either the extent record is full or the request is satisfied.
 *Like allocateBlocks:forFork:getExtent:, this method does not associate the returned extents with a file. It assumes you're doing that.
 */
- (u_int64_t) allocateBytes:(u_int64_t)numBytes
	forFork:(ImpForkType)forkType
	populateExtentRecord:(struct HFSPlusExtentDescriptor *_Nonnull const)outExts;

@end
