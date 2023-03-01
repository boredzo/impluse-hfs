//
//  ImpHFSVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

@class ImpBTreeFile;
@class ImpTextEncodingConverter;

#import "ImpForkUtilities.h"

@interface ImpHFSVolume : NSObject

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
@property(nonatomic, readonly) u_int64_t totalSizeInBytes;

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

///For subclass implementations of readAllocationBitmapFromFileDescriptor:.
- (void) setAllocationBitmapData:(NSMutableData *_Nonnull const)bitmapData numberOfBits:(u_int32_t const)numBits;

- (NSData *_Nonnull)bootBlocks;
- (void) getVolumeHeader:(void *_Nonnull const)outMDB;
- (void) peekAtHFSVolumeHeader:(void (^_Nonnull const)(struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr NS_NOESCAPE))block;

- (NSData *_Nonnull)volumeBitmap;
///Calculate the number of bits in the bitmap that are zero. Should match the drFreeBks/freeBlocks value in the volume header.
- (u_int32_t) numberOfBlocksFreeAccordingToBitmap;
///Identify which blocks are marked as allocated in the volume bitmap but have not been read from, and print those to the log.
- (void) reportBlocksThatAreAllocatedButHaveNotBeenAccessed;

@property(strong) ImpBTreeFile *_Nonnull catalogBTree;
@property(strong) ImpBTreeFile *_Nonnull extentsOverflowBTree;

- (NSString *_Nonnull) volumeName;
- (NSUInteger) numberOfBytesPerBlock;
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

#pragma mark -

///Read fork contents from the sections of the volume indicated by the given extents.
- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	logicalLength:(u_int64_t const)numBytes
	extents:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError;

///Low-level method intended for subclasses implementing their own versions of the higher-level readDataFromFileDescriptor:logicalLength:… method. This effectively takes one extent, using HFS+'s larger type for block numbers.
///Returns intoData on success; nil on failure. The copy's destination starts offset bytes into the data.
- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	startBlock:(u_int32_t const)startBlock
	blockCount:(u_int32_t const)blockCount
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError;

///Returns true if none of the extents in this record overlap. Returns false if there are overlapping extents, which may jeopardize user data or lead to volume corruption. Ignores any extents after an empty extent.
- (bool) checkHFSExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec;

///For every extent in the file (the initial three plus any overflow records) until an empty extent, call the block with that extent and the number of bytes remaining in the file. The block should return the number of bytes it consumed (e.g., read from the file descriptor). Returns the total number of bytes consumed.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const fileData, u_int64_t const logicalLength))block;

@end
