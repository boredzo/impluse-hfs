//
//  ImpSourceVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpSourceVolume.h"

#import "ImpByteOrder.h"
#import "ImpPrintf.h"
#import "ImpSizeUtilities.h"
#import "ImpForkUtilities.h"
#import "NSData+ImpSubdata.h"
#import "ImpTextEncodingConverter.h"
#import "ImpExtentSeries.h"
#import "ImpBTreeFile.h"

#import "ImpHFSSourceVolume.h"

@interface ImpSourceVolume ()

@property(readwrite, nonnull, strong) ImpTextEncodingConverter *textEncodingConverter;

@end

@implementation ImpSourceVolume
{
	NSData *_lastBlockData;
	NSMutableData *_volumeBitmapData;
}

- (void) impluseBugDetected_messageSentToAbstractClass {
	NSAssert(false, @"Message %s sent to instance of class %@, which hasn't implemented it (instance of abstract class, method not overridden, or super called when it shouldn't have been)", sel_getName(_cmd), [self class]);
}

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD
	startOffsetInBytes:(u_int64_t)startOffset
	lengthInBytes:(u_int64_t)lengthInBytes
	textEncoding:(TextEncoding const)hfsTextEncoding
{
	if ((self = [super init])) {
		_fileDescriptor = readFD;
		_startOffsetInBytes = startOffset;
		_lengthInBytes = lengthInBytes;
		_textEncodingConverter = [[ImpTextEncodingConverter alloc] initWithHFSTextEncoding:hfsTextEncoding];
	}
	return self;
}

- (void) dealloc {
	if (_bitVector != NULL) {
		CFRelease(_bitVector);
	}
}

- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	_bootBlocksData = [NSMutableData dataWithLength:kISOStandardBlockSize * 2];
	ssize_t const amtRead = pread(readFD, _bootBlocksData.mutableBytes, _bootBlocksData.length, _startOffsetInBytes + kISOStandardBlockSize * 0);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume boot blocks" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < _bootBlocksData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume boot blocks — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the boot blocks other than write 'em out verbatim to the HFS+ volume, but that comes later.
	return true;
}

- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

- (void) setAllocationBitmapData:(NSMutableData *_Nonnull const)bitmapData numberOfBits:(u_int32_t const)numBits {
	_volumeBitmapData = bitmapData;
	_bitVector = CFBitVectorCreate(kCFAllocatorDefault, _volumeBitmapData.bytes, numBits);

	_blocksThatAreAllocatedButWereNotAccessed = CFBitVectorCreateMutableCopy(kCFAllocatorDefault, numBits, _bitVector);
}

- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}
- (bool)readCatalogFileFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}
- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD tapURL:(NSURL *_Nullable const)tapURL error:(NSError *_Nullable *_Nonnull const)outError {
	[self impluseBugDetected_messageSentToAbstractClass];
	return false;
}

- (bool) readLastBlockFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError {
	NSMutableData *_Nonnull const lastBlockData = [NSMutableData dataWithLength:kISOStandardBlockSize];
	ssize_t const amtRead = pread(readFD, lastBlockData.mutableBytes, lastBlockData.length, _startOffsetInBytes + _lengthInBytes - kISOStandardBlockSize);
	if (amtRead < 0) {
		NSError *_Nonnull const readError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Error reading source volume last block" }];
		if (outError != NULL) *outError = readError;
		return false;
	} else if ((NSUInteger)amtRead < lastBlockData.length) {
		NSError *_Nonnull const underrunError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: @"Unexpected end of file reading source volume last block — are you sure this is an HFS volume?" }];
		if (outError != NULL) *outError = underrunError;
		return false;
	}
	//We don't do anything with the last block other than write it out verbatim to the HFS+ volume, but that comes later.
	_lastBlockData = lastBlockData;
	return true;
}

- (bool)loadAndReturnError:(NSError *_Nullable *_Nonnull const)outError {
	int const readFD = self.fileDescriptor;
	return (
		[self readBootBlocksFromFileDescriptor:readFD error:outError]
		&&
		[self readVolumeHeaderFromFileDescriptor:readFD error:outError]
		&&
		[self readAllocationBitmapFromFileDescriptor:readFD tapURL:nil error:outError]
		&&
		[self readExtentsOverflowFileFromFileDescriptor:readFD tapURL:nil error:outError]
		&&
		[self readCatalogFileFromFileDescriptor:readFD tapURL:nil error:outError]
		&&
		[self readLastBlockFromFileDescriptor:readFD error:outError]
	);
}

#pragma mark -

- (NSData *_Nullable) dataForBlocksStartingAt:(u_int32_t const)startBlock count:(u_int32_t const)blockCount {
	NSUInteger const blockSize = self.numberOfBytesPerBlock;
	NSMutableData *_Nonnull const intoData = [NSMutableData dataWithLength:blockSize * blockCount];
	off_t const readStart = self.startOffsetInBytes + self.offsetOfFirstAllocationBlock + startBlock * blockSize;
	enum { offset = 0 };
	size_t const numBytesToRead = intoData.length - offset;
	ssize_t const amtRead = pread(self.fileDescriptor, intoData.mutableBytes + offset, numBytesToRead, readStart);
	return amtRead > 0 ? intoData : nil;
}
- (NSData *_Nullable) dataForBlock:(u_int32_t)aBlock {
	return [self dataForBlocksStartingAt:aBlock count:1];
}

#pragma mark -

- (NSData *_Nonnull)bootBlocks {
	return _bootBlocksData;
}
- (NSData *_Nonnull)lastBlock {
	return _lastBlockData;
}
- (NSData *_Nonnull) volumeBitmap {
	return _volumeBitmapData;
}

- (bool) isBlockInBounds:(u_int32_t const)blockNumber {
	return blockNumber < self.numberOfBlocksTotal;
}
- (bool) isBlockAllocated:(u_int32_t const)blockNumber {
	return CFBitVectorGetBitAtIndex(_bitVector, blockNumber);
}

- (u_int32_t) numberOfBlocksFreeAccordingToBitmap {
	return (u_int32_t)CFBitVectorGetCountOfBit(_bitVector, (CFRange){ 0, self.numberOfBlocksTotal }, false);
}

- (void) reportBlocksThatAreAllocatedButHaveNotBeenAccessed {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	CFRange searchRange = entireRange;
	CFRange foundRange;
	while ((foundRange.location = CFBitVectorGetFirstIndexOfBit(_blocksThatAreAllocatedButWereNotAccessed, searchRange, true)) != kCFNotFound) {
		searchRange.length -= foundRange.location - searchRange.location;
		searchRange.location = foundRange.location;

		CFIndex const lastMissedBit = CFBitVectorGetLastIndexOfBit(_blocksThatAreAllocatedButWereNotAccessed, searchRange, true);
		foundRange.length = (lastMissedBit - foundRange.location) + 1;
		ImpPrintf(@"Blocks that have not been accessed: %lu through %lu (%lu blocks)", foundRange.location, lastMissedBit, foundRange.length);

		searchRange.length -= foundRange.length;
		searchRange.location += foundRange.length;
	}
	NSUInteger const numUnreadBlocks = CFBitVectorGetCountOfBit(_blocksThatAreAllocatedButWereNotAccessed, entireRange, true);
	if (numUnreadBlocks > 0) {
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu have not been read from", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numUnreadBlocks);
	}
}
- (u_int32_t) numberOfBlocksThatAreAllocatedButHaveNotBeenAccessed {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	NSUInteger const numUnreadBlocks = CFBitVectorGetCountOfBit(_blocksThatAreAllocatedButWereNotAccessed, entireRange, true);
	if (numUnreadBlocks > 0) {
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu have not been read from", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numUnreadBlocks);
	}

	return numUnreadBlocks > UINT32_MAX ? UINT32_MAX : (u_int32_t)numUnreadBlocks;
}
- (void) findExtents:(void (^_Nonnull const)(NSRange))block inBitVector:(CFBitVectorRef _Nonnull const)bitVector {
	CFRange const entireRange = { 0, self.numberOfBlocksTotal };
	CFRange searchRange = entireRange;
	CFRange foundRange;
	while ((foundRange.location = CFBitVectorGetFirstIndexOfBit(bitVector, searchRange, true)) != kCFNotFound) {
		searchRange.length -= foundRange.location - searchRange.location;
		searchRange.location = foundRange.location;

		CFIndex const lastMissedBit = CFBitVectorGetLastIndexOfBit(bitVector, searchRange, true);
		foundRange.length = (lastMissedBit - foundRange.location) + 1;

		NSRange const extent = { foundRange.location, foundRange.length };
		block(extent);

		searchRange.length -= foundRange.length;
		searchRange.location += foundRange.length;
	}
}
- (void) findExtentsThatAreAllocatedButHaveNotBeenAccessed:(void (^_Nonnull const)(NSRange))block {
	[self findExtents:block inBitVector:_blocksThatAreAllocatedButWereNotAccessed];
}
- (void) findExtentsThatAreAllocatedButAreNotReferencedInTheBTrees:(void (^_Nonnull const)(NSRange))block {
	[self impluseBugDetected_messageSentToAbstractClass];
}
- (NSUInteger) numberOfBlocksThatAreAllocatedButAreNotReferencedInTheBTrees {
	__block NSUInteger numOrphanedBlocks = 0;
	[self findExtentsThatAreAllocatedButAreNotReferencedInTheBTrees:^(NSRange extentRange) {
		numOrphanedBlocks += extentRange.length;
	}];
	if (numOrphanedBlocks > 0) {
		CFRange const entireRange = { 0, self.numberOfBlocksTotal };
		ImpPrintf(@"Of the %lu blocks that are marked as allocated, %lu are not claimed by any fork", CFBitVectorGetCountOfBit(_bitVector, entireRange, true), numOrphanedBlocks);
	}

	return numOrphanedBlocks;
}

- (u_int64_t) lengthInBytes {
	return (
		_lengthInBytes > 0
		? _lengthInBytes
		: self.numberOfBytesPerBlock * (u_int64_t)self.numberOfBlocksTotal
	);
}

- (u_int32_t) firstPhysicalBlockOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (off_t) offsetOfFirstAllocationBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return -1;
}
- (HFSCatalogNodeID) nextCatalogNodeID {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSString *_Nonnull) volumeName {
	[self impluseBugDetected_messageSentToAbstractClass];
	return @"Unknown volume";
}
- (u_int32_t) numberOfBytesPerBlock {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksTotal {
	[self impluseBugDetected_messageSentToAbstractClass];
	return 0;
}
- (NSUInteger) numberOfBlocksUsed {
	return self.numberOfBlocksTotal - self.numberOfBlocksFree;
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

#pragma mark Reading fork contents

- (bool) readIntoData:(NSMutableData *_Nonnull const)intoData
	atOffset:(NSUInteger)offset
	fromFileDescriptor:(int const)readFD
	startBlock:(u_int32_t const)startBlock
	blockCount:(u_int32_t const)blockCount
	actualAmountRead:(u_int64_t *_Nonnull const)outAmtRead
	error:(NSError *_Nullable *_Nonnull const)outError
{
	int32_t firstUnallocatedBlockNumber = -1;
	//TODO: Optimize using CFBitVectorGetCountOfBit (start range at startBlock, check returned count >= blockCount)
	for (u_int16_t i = 0; i < blockCount; ++i) {
//		ImpPrintf(@"- #%u: %@", startBlock + i, CFBitVectorGetBitAtIndex(_bitVector, startBlock + i) ? @"YES" : @"NO!");
		if (! [self isBlockAllocated:startBlock + i]) {
			firstUnallocatedBlockNumber = startBlock + i;
		}
	}
//	ImpPrintf(@"Extent starting at %u is fully allocated before reading: %@", startBlock, (firstUnallocatedBlockNumber < 0) ? @"YES" : @"NO");
	if (firstUnallocatedBlockNumber > -1) {
		//It's possible that this should be a warning, or that its level of fatality should be adjustable (particularly in situations of data recovery).
		NSError *_Nonnull const readingIntoTheVoidError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadCorruptFileError userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:NSLocalizedString(@"Attempt to read block #%u, which is unallocated; this may indicate a bug in this program, or that the volume itself was corrupt (please save a copy of it using bzip2)", @""), firstUnallocatedBlockNumber] }];
		if (outError != NULL) {
			*outError = readingIntoTheVoidError;
		}
		return false;
	}

	off_t const readStart = self.startOffsetInBytes + self.offsetOfFirstAllocationBlock + startBlock * self.numberOfBytesPerBlock;
	size_t const numBytesToRead = intoData.length - offset;
	size_t const numBlocksToRead = ImpCeilingDivide(intoData.length, self.numberOfBytesPerBlock);
	if (_blocksThatAreAllocatedButWereNotAccessed != NULL) {
		CFBitVectorSetBits(_blocksThatAreAllocatedButWereNotAccessed, (CFRange) { startBlock, numBlocksToRead }, false);
	}
//	ImpPrintf(@"Reading 0x%lx bytes (%lu bytes = %lu blocks) from source volume starting at 0x%llx bytes (extent: [ start #%u, %u blocks ])", intoData.length, intoData.length, ImpCeilingDivide(intoData.length, self.numberOfBytesPerBlock), readStart, startBlock, blockCount);
	if (numBlocksToRead < blockCount) {
		NSLog(@"Underrun alert! Data is not big enough to hold this extent. Only reading %zu blocks out of this extent's %u blocks", numBlocksToRead, blockCount);
	}
	ssize_t const amtRead = pread(readFD, intoData.mutableBytes + offset, numBytesToRead, readStart);
	if (outAmtRead != NULL) {
		*outAmtRead = amtRead;
	}
	if (amtRead < 0) {
		NSError *_Nonnull const readFailedError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Failed to read data from extent { start #%u, %u blocks }", (unsigned)startBlock, (unsigned)blockCount ] }];
		if (outError != NULL) {
			*outError = readFailedError;
		}
		return false;
	}

	return true;
}

@end
