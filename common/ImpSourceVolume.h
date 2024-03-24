//
//  ImpSourceVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

@class ImpBTreeFile;
@class ImpTextEncodingConverter;

#import "ImpForkUtilities.h"

@interface ImpSourceVolume : NSObject
{
	NSMutableData *_bootBlocksData;
	CFBitVectorRef _bitVector;
	CFMutableBitVectorRef _blocksThatAreAllocatedButWereNotAccessed;

	u_int64_t _startOffsetInBytes, _lengthInBytes;
	int _fileDescriptor;
}

///Initializer to be overridden by subclasses. Do not use to directly instantiate the abstract class.
///startOffset should be 0 for volumes from bare-volume images. For volumes found in a partition map, startOffset should be the offset into the device/image in bytes where the preamble starts.
///lengthInBytes can be 0, in which case the whole device/image should be used.
- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD
	startOffsetInBytes:(u_int64_t)startOffset
	lengthInBytes:(u_int64_t)lengthInBytes
	textEncoding:(TextEncoding const)hfsTextEncoding;

///Returns an object that can convert strings (names) between this HFS volume's 8-bit-per-character encoding and Unicode.
@property(readonly, nonnull, strong) ImpTextEncodingConverter *textEncodingConverter;

@property(readonly) int fileDescriptor;

///The offset in bytes into the volume at which the volume's preamble is expected to start. For raw volume images, this will be 0. For volumes extracted from partitioned images, this will be non-zero.
@property(readonly) u_int64_t startOffsetInBytes;

///The total length of the volume, from preamble to postamble. May be an estimate based on the volume header, if the volume was created from a device.
@property(nonatomic, readonly) u_int64_t lengthInBytes;

///Read the boot blocks, volume header, and allocation bitmap in that order, followed by the extents overflow file and catalog file.
- (bool)loadAndReturnError:(NSError *_Nullable *_Nonnull const)outError;

///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
///Finer-grained method intended specifically for the analyze command. Most other uses should use loadAndReturnError:.
- (bool) readLastBlockFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;

///For subclass implementations of readAllocationBitmapFromFileDescriptor:.
- (void) setAllocationBitmapData:(NSMutableData *_Nonnull const)bitmapData numberOfBits:(u_int32_t const)numBits;

- (NSData *_Nonnull)bootBlocks;
///The last block in the volume, immediately following the alternate volume header. Always 0x200 bytes.
- (NSData *_Nonnull)lastBlock;

- (NSData *_Nonnull)volumeBitmap;
///Calculate the number of bits in the bitmap that are zero. Should match the drFreeBks/freeBlocks value in the volume header.
- (u_int32_t) numberOfBlocksFreeAccordingToBitmap;
///Returns whether a block number is less than the number of blocks in the volume according to the volume header. Used by analyze as part of consistency checking of extents.
- (bool) isBlockInBounds:(u_int32_t const)blockNumber;
///Returns whether a block is marked as in use according to the volume bitmap. Does not guarantee that the block is actually referred to by an extent in the catalog or extents overflow trees.
- (bool) isBlockAllocated:(u_int32_t const)blockNumber;

///Abstract method for subclasses.
- (void) findExtents:(void (^_Nonnull const)(NSRange))block inBitVector:(CFBitVectorRef _Nonnull const)bitVector;

///Identify which blocks are marked as allocated in the volume bitmap but have not been read from, and print those to the log.
- (void) reportBlocksThatAreAllocatedButHaveNotBeenAccessed;
///Count how many blocks are marked as allocated in the volume bitmap but have not been read from. Use this method after all files have been copied when identifying orphaned blocks for recovery.
- (u_int32_t) numberOfBlocksThatAreAllocatedButHaveNotBeenAccessed;
///Call the block with an NSRange containing each contiguous extent of blocks that are marked as allocated in the volume bitmap but have not been read from. Use this method after all files have been copied when identifying orphaned blocks for recovery.
- (void) findExtentsThatAreAllocatedButHaveNotBeenAccessed:(void (^_Nonnull const)(NSRange))block;

- (NSUInteger) numberOfBlocksThatAreAllocatedButAreNotReferencedInTheBTrees;

@property(strong) ImpBTreeFile *_Nonnull catalogBTree;
@property(strong) ImpBTreeFile *_Nonnull extentsOverflowBTree;

- (NSString *_Nonnull) volumeName;
- (u_int32_t) firstPhysicalBlockOfFirstAllocationBlock;
///The offset in bytes at which the first allocation block begins. (I.e., firstPhysicalBlockOfFirstAllocationBlock converted to a byte offset.)
- (off_t) offsetOfFirstAllocationBlock;
- (HFSCatalogNodeID) nextCatalogNodeID;
- (u_int32_t) numberOfBytesPerBlock;
///The total number of allocation blocks in the volume, according to the volume header.
- (NSUInteger) numberOfBlocksTotal;
- (NSUInteger) numberOfBlocksUsed;
- (NSUInteger) numberOfBlocksFree;
///Total number of files in the whole volume.
- (NSUInteger) numberOfFiles;
///Total number of folders in the whole volume.
- (NSUInteger) numberOfFolders;

- (NSUInteger) catalogSizeInBytes;
- (NSUInteger) extentsOverflowSizeInBytes;

#pragma mark Reading fork contents

///Low-level method intended for subclasses implementing their own versions of the higher-level readDataFromFileDescriptor:logicalLength:… method. This effectively takes one extent, using HFS+'s larger type for block numbers.
///Returns intoData on success; nil on failure. The copy's destination starts offset bytes into the data.
- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	startBlock:(u_int32_t const)startBlock
	blockCount:(u_int32_t const)blockCount
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError;

@end
