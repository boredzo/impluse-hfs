//
//  ImpDestinationVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpDestinationVolume.h"

#import "NSData+ImpSubdata.h"
#import "ImpByteOrder.h"
#import "ImpPrintf.h"
#import "ImpSizeUtilities.h"

#import <sys/stat.h>
#import <hfs/hfs_format.h>

//For implementing the read side
#import "ImpTextEncodingConverter.h"
#import "ImpBTreeFile.h"

#import "ImpVirtualFileHandle.h"

@interface ImpDestinationVolume ()

- (u_int32_t) numBlocksForPreambleWithSize:(u_int32_t const)aBlockSize;
- (u_int32_t) numBlocksForPostambleWithSize:(u_int32_t const)aBlockSize;

///Low-level method. Marks the blocks within the extent as allocated.
///WARNING: This method does not check that these blocks are available/not already allocated. It is meant for implementing higher-level allocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) allocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

///Low-level method. Marks the blocks within the extent as unallocated (available).
///You should not use this extent afterward, or write to any blocks newly freed.
///WARNING: This method does not check that these blocks are allocated, nor does it make sure nothing is using these blocks. It is meant for implementing higher-level allocation and deallocation methods, such as those declared in the header, that do perform such checks. You probably want one of those.
- (void) deallocateBlocksOfExtent:(const struct HFSPlusExtentDescriptor *_Nonnull const)oneExtent;

@end

@implementation ImpDestinationVolume

- (void) impluseBugDetected_messageSentToAbstractClass {
	NSAssert(false, @"Message %s sent to instance of class %@, which hasn't implemented it (instance of abstract class, method not overridden, or super called when it shouldn't have been)", sel_getName(_cmd), [self class]);
}

- (instancetype _Nonnull)initForWritingToFileDescriptor:(int)writeFD
	startAtOffset:(u_int64_t)startOffsetInBytes
	expectedLengthInBytes:(u_int64_t)lengthInBytes
{
	if ((self = [super init])) {
		_fileDescriptor = writeFD;

		_startOffsetInBytes = startOffsetInBytes;
		_lengthInBytes = lengthInBytes;

		self.textEncodingConverter = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:kTextEncodingMacRoman];
	}
	return self;
}

- (bool) flushVolumeStructures:(NSError *_Nullable *_Nullable const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

+ (u_int32_t) optimalAllocationBlockSizeForVolumeLength:(u_int64_t)numBytes {
	u_int32_t naiveBlockSize = (u_int32_t)(numBytes / UINT32_MAX);
	if (naiveBlockSize % kISOStandardBlockSize != 0) {
		naiveBlockSize += kISOStandardBlockSize - (naiveBlockSize % kISOStandardBlockSize);
	}

	u_int32_t validBlockSize;
	for (validBlockSize = kISOStandardBlockSize; validBlockSize < naiveBlockSize; validBlockSize *= 2);

	return validBlockSize;
}

///Note that this may return a number larger than can fit in a u_int32_t, and thus larger than can be stored in a single extent. If the return value is greater than UINT_MAX, you should allocate multiple extents as needed to whittle it down to fit.
- (u_int64_t) countOfBlocksOfSize:(u_int32_t const)blockSize neededForLogicalLength:(u_int64_t const)length {
	u_int64_t const numBlocks = ImpCeilingDivide(length, blockSize);

	return numBlocks;
}

#pragma mark Writing data

- (ImpVirtualFileHandle *_Nonnull const) fileHandleForWritingToExtents:(struct HFSPlusExtentDescriptor const *_Nonnull const)extentRecPtr {
	return [[ImpVirtualFileHandle alloc] initWithVolume:self extents:extentRecPtr];
}

- (int64_t)writeData:(NSData *const)data startingFrom:(u_int64_t)offsetInData toExtent:(const struct HFSPlusExtentDescriptor *const)oneExtent error:(NSError * _Nullable __autoreleasing *const)outError {
	void const *_Nonnull const bytesPtr = data.bytes;

	uint64_t bytesToWrite = data.length - offsetInData;
	if (bytesToWrite <= 0) {
		NSAssert(bytesToWrite >= 0, @"Invalid offset for data: This offset (%llu bytes) would start past the end of the data (%lu bytes).", offsetInData, data.length);
		return bytesToWrite;
	}

	//TODO: This is an out-of-bounds read. Does this actually make any sense? At all?
	/*
	//Only write as many bytes as will fit in this extent, and not one more.
	uint64_t const extentLengthInBytes = L(oneExtent->blockCount) * self.numberOfBytesPerBlock;
	if (extentLengthInBytes > bytesToWrite) {
		bytesToWrite = extentLengthInBytes;
	}
	 */

	u_int64_t const volumeStartInBytes = self.startOffsetInBytes;
	off_t const extentStartInBytes = L(oneExtent->startBlock) * self.numberOfBytesPerBlock;
//	ImpPrintf(@"Writing %lu bytes to output volume starting at a-block #%u (output file offset %llu bytes)", data.length, L(oneExtent->startBlock), volumeStartInBytes + extentStartInBytes);
	int64_t const amtWritten = pwrite(_fileDescriptor, bytesPtr + offsetInData, bytesToWrite, volumeStartInBytes + extentStartInBytes);

	if (amtWritten < 0) {
		NSError *_Nonnull const writeError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Failed to write 0x%llx (%llu) bytes (range of data { %llu, %lu }) starting at 0x%llx bytes", @""), bytesToWrite, bytesToWrite, offsetInData, data.length, extentStartInBytes] }];
		if (outError != NULL) {
			*outError = writeError;
		}
	}

	return amtWritten;
}

- (int64_t)writeData:(NSData *const)data startingFrom:(u_int64_t)offsetInData toExtents:(const struct HFSPlusExtentDescriptor *const)extentRec error:(NSError * _Nullable __autoreleasing *const)outError {
	int64_t totalWritten = 0;
	for (NSUInteger i = 0; i < kHFSPlusExtentDensity; ++i) {
		int64_t const amtWritten = [self writeData:data startingFrom:offsetInData toExtent:extentRec + i error:outError];
		if (amtWritten < 0) {
			return amtWritten;
		} else {
			totalWritten += amtWritten;
			offsetInData += amtWritten;
		}
	}
	return totalWritten;
}

- (off_t) offsetOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return -1;
}

- (NSString *_Nonnull const) volumeName {
	[self impluseBugDetected_messageSentToAbstractClass];
	return @":::Volume root not found:::";
}

- (NSUInteger) numberOfBytesPerBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksTotal {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksFree {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfFiles {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfFolders {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}

- (NSUInteger) catalogSizeInBytes {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) extentsOverflowSizeInBytes {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}

@end
