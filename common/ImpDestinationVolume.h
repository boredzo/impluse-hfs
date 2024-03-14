//
//  ImpDestinationVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

#import "ImpForkUtilities.h"

@class ImpTextEncodingConverter;
@class ImpVirtualFileHandle;

///Like ImpSourceVolume, this wraps a file descriptor and is responsible for volume structures (primarily the volume header and allocations bitmap).
///Unlike ImpSourceVolume, this is not (at least primarily) for reading an existing volume from disk, but for writing a new volume to disk. As such, its interface is quite different. An ImpDestinationVolume is used by an HFS-to-HFS+ converter to initialize the HFS+ volume structures and take receipt of special and user file contents, including the catalog file.
@interface ImpDestinationVolume : NSObject
{
	u_int64_t _startOffsetInBytes;
	u_int64_t _lengthInBytes;
}

- (instancetype _Nonnull)initForWritingToFileDescriptor:(int)writeFD
	startAtOffset:(u_int64_t)startOffsetInBytes
	expectedLengthInBytes:(u_int64_t)lengthInBytes;

@property(readonly) int fileDescriptor;
@property(readonly) u_int64_t startOffsetInBytes;
@property(readonly) u_int64_t lengthInBytes;

///Returns the size in bytes of each allocation block. Undefined if this hasn't been set yet.
@property(nonatomic, readonly) u_int32_t numberOfBytesPerBlock;

///The total number of allocation blocks in the volume, according to the volume header.
- (NSUInteger) numberOfBlocksTotal;

@property(readwrite, nonnull, strong) ImpTextEncodingConverter *textEncodingConverter;

#pragma mark Block allocation

///Calculate the minimum physical length in blocks for a fork of a given logical length in bytes.
- (u_int64_t) countOfBlocksOfSize:(u_int32_t const)blockSize neededForLogicalLength:(u_int64_t const)length;

///Given a volume length, return a valid block size that will be usable for a volume of that size.
///HFS+ (TN1150) requires block sizes to be a multiple of 0x200 and a power of two. This method will find the smallest block size that fits those constraints.
+ (u_int32_t) optimalAllocationBlockSizeForVolumeLength:(u_int64_t)numBytes;

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

#pragma mark Writing volume structures

///Write a temporary preamble to the destination file's first 3 * kISOStandardBlockSize bytes that includes the converted volume header in the wrong location (so it won't mount), as well as explanatory text that says if you're reading this, the conversion failed. This preamble must be overwritten with the real preamble as the last step in conversion.
- (bool) writeTemporaryPreamble:(out NSError *_Nullable *_Nullable const)outError;

///Write all of the volume structures, including the volume header and all special files (catalog, etc.). to the appropriate extents in the file descriptor.
///This should be the very last step after copying user data into the volume, since writing these structures makes the volume mountable, and closing the file descriptor will cue Disk Arbitration to search the file for mountable volumes.
- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError;

@end
