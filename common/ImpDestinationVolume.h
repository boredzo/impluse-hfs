//
//  ImpDestinationVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

#import <hfs/hfs_format.h>

#import "ImpSourceVolume.h"

#import "ImpForkUtilities.h"

///This is a simple file-handle-like object for writing to files within the HFS+ volume. Writes may be buffered, but ultimately will hit the real backing file via the volume's file descriptor.
@interface ImpVirtualFileHandle : NSObject

///The total size of all blocks in all extents currently backing this file handle. This is the limit of how much data you can write to this file handle.
@property u_int64_t totalPhysicalSize;

///If the file in question has even more extents in the extents overflow file, call this to extend the file handle's knowledge of where it can write data into.
- (void) growIntoExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr;

///Write some data to the file. The new data will be appended immediately after any data previously written to the same file handle. Returns the number of bytes written, or -1 in case of error. If this returns zero (or otherwise less data than you tried to write), the file handle's backing extents are full and you need to grow the handle into more extents to be able to write more data.
- (NSInteger) writeData:(NSData *_Nonnull const)data error:(NSError *_Nullable *_Nonnull const)outError;

///Flush any pending writes and bar any further writes.
- (void) closeFile;

@end

///Like ImpSourceVolume, this wraps a file descriptor and is responsible for volume structures (primarily the volume header and allocations bitmap).
///Unlike ImpSourceVolume, this is not (at least primarily) for reading an existing volume from disk, but for writing a new volume to disk. As such, its interface is quite different. An ImpDestinationVolume is used by an HFS-to-HFS+ converter to initialize the HFS+ volume structures and take receipt of special and user file contents, including the catalog file.
///ImpDestinationVolume is a subclass of ImpSourceVolume so that the same methods can be used to read (or diagnose) an HFS+ volume.
@interface ImpDestinationVolume : ImpSourceVolume

- (instancetype _Nonnull)initForWritingToFileDescriptor:(int)writeFD
	startAtOffset:(u_int64_t)startOffsetInBytes
	expectedLengthInBytes:(u_int64_t)lengthInBytes;

///Write all of the volume structures, including the volume header and all special files (catalog, etc.). to the appropriate extents in the file descriptor.
///This should be the very last step after copying user data into the volume, since writing these structures makes the volume mountable, and closing the file descriptor will cue Disk Arbitration to search the file for mountable volumes.
- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError;

@property(nonatomic, copy) NSData *_Nonnull bootBlocks;
@property(nonatomic, copy) NSData *_Nonnull lastBlock;
@property(nonatomic, copy) NSData *_Nonnull volumeHeader;

- (void) peekAtHFSPlusVolumeHeader:(void (^_Nonnull const)(struct HFSPlusVolumeHeader const *_Nonnull const vhPtr NS_NOESCAPE))block;

///For use by HFS-to-HFS+ converter objects to make changes to the HFS+ volume header during conversion.
- (struct HFSPlusVolumeHeader *_Nonnull const) mutableVolumeHeaderPointer;

///Set the size of each allocation block, and the total number of them. As allocation blocks in HFS+ span from the boot blocks to the footer, this sets the size of the volume.
///You should not call this method after anything that has allocated blocks past the volume header (including populating the catalog file), because this method creates the allocations bitmap and initializes it to allocate only the minimum set of a-blocks (those containing the volume header and other required sectors and nothing else).
///aBlockSize must be a multiple of kISOStandardBlockSize (0x200 bytes), and a power of two.
- (void) initializeAllocationBitmapWithBlockSize:(u_int32_t)aBlockSize count:(u_int32_t)numABlocks;

///Convenience method that adds enough blocks to contain the required sectors (volume header, etc.) that aren't considered allocation blocks under HFS. For large block sizes, this may add as few as two blocks; for the smallest block size of 0x200 bytes, it will add five (two for the boot blocks, a third for the volume header, and two more at the end for the alternate volume header and the footer).
- (void) setAllocationBlockSize:(u_int32_t)aBlockSize countOfUserBlocks:(u_int32_t)numABlocks;

///Walks through the in-progress allocations file counting up free blocks, and returns the count. This is used to update the volume header after changes that may allocate or deallocate blocks.
///(Note that this is used when *creating* HFS+ volumes, whereas the superclass method with a similar name and purpose is for volumes being *read in*.)
- (u_int32_t) numberOfBlocksFreeAccordingToWorkingBitmap;

///Returns the size in bytes of each allocation block. Undefined if this hasn't been set yet.
@property(nonatomic, readonly) u_int32_t blockSize;

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

///Clear the bits of the allocations bitmap corresponding to the blocks covered by this extent. You should not use this extent afterward, or write to any blocks newly freed.
- (void) deallocateBlocksOfExtent:(struct HFSPlusExtentDescriptor const *_Nonnull const)oneExtent;

#pragma mark Reading fork contents

///Read fork contents from the sections of the volume indicated by the given extents.
- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	logicalLength:(u_int64_t const)numBytes
	bigExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)hfsPlusExtRec
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError;

///For every extent in the file (the initial eight plus any overflow records) until an empty extent, call the block with that extent and the number of bytes remaining in the file. The block should return the number of bytes it consumed (e.g., read from the file descriptor). Returns the total number of bytes consumed.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithBigExtentsRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const forkData, u_int64_t const logicalLength))block;

#pragma mark Writing fork contents

///Create a file handle for writing fork contents to the extents in the given extent record. extentRecPtr must point to kHFSPlusExtentDensity file descriptors.
- (ImpVirtualFileHandle *_Nonnull const) fileHandleForWritingToExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr;

/*!Writes data to the backing file descriptor using the contents of this extent to indicate where. Returns the number of bytes that were written.
 * Generally, a partial write (return value less than data.length) should only occur if the extent was filled. Call this method again with offsetInData increased by the previous return value, and the next extent in the fork's extent record.
 * This method does not allocate new extents. You must call this method with an extent you have already allocated using the extent allocation methods described above.
 * Returns a negative number if the underlying write system call did, or if you pass an offsetInData that is greater than the data's length. If offsetInData == data.length, returns 0.
 */
- (int64_t) writeData:(NSData *_Nonnull const)data
	startingFrom:(u_int64_t)offsetInData
	toExtent:(struct HFSPlusExtentDescriptor const *_Nonnull const)oneExtent
	error:(NSError *_Nullable *_Nullable const)outError;

/*!Writes data to the backing file descriptor using the extents of one HFS+ extent record to indicate where. Returns the number of bytes that were written.
 * extentRec *must* point to an HFSPlusExtentRecord (an array of eight extent descriptors). Bad things will happen if you pass a single extent or a partial extent record to this method.
 * Generally, a partial write (return value less than data.length) should only occur if all of the extents were filled. Call this method again with offsetInData increased by the previous return value, and the fork's next extent record from the extents overflow file.
 * This method does not allocate new extents. You must call this method with extents you have already allocated using the extent allocation methods described above.
 * Returns a negative number if the underlying write system call did, or if you pass an offsetInData that is greater than the data's length. If offsetInData == data.length, returns 0.
 */
- (int64_t) writeData:(NSData *_Nonnull const)data
	startingFrom:(u_int64_t)offsetInData
	toExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRec
	error:(NSError *_Nullable *_Nullable const)outError;

///Write a temporary preamble to the destination file's first 3 * kISOStandardBlockSize bytes that includes the converted volume header in the wrong location (so it won't mount), as well as explanatory text that says if you're reading this, the conversion failed. This preamble must be overwritten with the real preamble as the last step in conversion.
- (bool) writeTemporaryPreamble:(out NSError *_Nullable *_Nullable const)outError;

@end
